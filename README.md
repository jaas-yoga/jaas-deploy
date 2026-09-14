# jaas-deploy

Single point of build & deploy for the jaas stack — **no Docker**. Replaces
the per-repo `docker-publish.yml` + Docker Compose path (still documented in
jaas-ui's `deploy/`) with native artifacts running under systemd on two
OCI Always Free VMs.

## Why no Docker

`jaas-ui` already builds a self-contained artifact via Next's
`output: "standalone"` (traces only the files each page needs, plus
`node_modules`). The two Python services (`jaas-skills`'s registry,
`jaas-guardrails`) use `uv` with a committed lockfile — `uv sync --frozen`
on the target VM reproduces the exact same dependency set Docker would have
baked into an image. Docker's container-runtime overhead is small in
absolute terms, but on a `VM.Standard.E2.1.Micro` (1 GB RAM, 1/8 OCPU) every
MB matters, and it also removes multi-arch build complexity: CI runs on
`ubuntu-latest` (x86_64), matching the VM's architecture, so native
Node modules (e.g. `sharp`) never need cross-compilation.

## Architecture

Two VMs (both `VM.Standard.E2.1.Micro`, OCI Always Free):

| VM | Runs | Public? |
|---|---|---|
| **web** | Caddy (TLS for `DOMAIN`) + `jaas-ui` (`:3027`, loopback only) | Yes, 80/443 |
| **api** | Caddy (TLS for `API_DOMAIN`) + `jaas-registry` (`:8027`, loopback) + `jaas-guardrails` (`:8028`, loopback) | Yes, 80/443 |

`jaas-ui` reaches `jaas-registry` over the VMs' **private** IPs within the
same OCI VCN (`JAAS_API_URL=http://<api-vm-private-ip>:8027`) — never over
the public internet, matching the security posture the old
`docker-compose.yml` had via its internal Docker network. `jaas-guardrails`
is colocated with `jaas-registry` on the api VM and bound to `127.0.0.1`
only — reachable from nowhere else, same as before.

`API_DOMAIN` gets its own Caddy/TLS on the api VM (rather than proxying
through the web VM) because GitHub's OAuth callback hits it directly from
the browser — see `jaas-registry`'s own comments on
`JAAS_GITHUB_OAUTH_REDIRECT_URI`.

Each VM keeps the last 5 releases under `/opt/jaas/<service>/releases/`,
with `/opt/jaas/<service>/current` symlinked to the live one — rollback is
`ln -sfn releases/<older> current && sudo systemctl restart jaas-<service>`.

## How a deploy happens

1. A push to `main` in `jaas-ui`, `jaas-skills`, or `jaas-guardrails`
   triggers that repo's own thin `.github/workflows/deploy.yml`, which
   calls this repo's reusable workflow
   (`jaas-yoga/jaas-deploy/.github/workflows/deploy.yml@main`) with
   `service: ui|registry|guardrails` and `target_host` set.
2. The reusable workflow (in **this** repo) checks out the caller repo,
   builds the artifact (`scripts/build-node.sh` or `scripts/build-python.sh`),
   then ships and activates it (`scripts/deploy.sh`) over SSH.
3. All actual build/deploy logic lives here — changing it (e.g. adding a
   new service, changing the release-retention count) never requires
   touching the three source repos again.

## One-time VM setup

On each fresh Ubuntu 24.04 `VM.Standard.E2.1.Micro`:

```bash
# from your machine
scp -r provisioning ubuntu@<web-vm-ip>:~/provisioning
ssh ubuntu@<web-vm-ip>
sudo bash ~/provisioning/provision-web-vm.sh <DOMAIN> "<deploy-ssh-public-key>"
```

```bash
scp -r provisioning ubuntu@<api-vm-ip>:~/provisioning
ssh ubuntu@<api-vm-ip>
sudo bash ~/provisioning/provision-api-vm.sh <API_DOMAIN> "<deploy-ssh-public-key>"
```

Both scripts are idempotent. After running them:

1. Fill in the empty secrets in `/opt/jaas/ui/shared/env` (web VM) and
   `/opt/jaas/registry/shared/env` (api VM) — these are outside the release
   tree so deploys never touch them.
2. Set `JAAS_API_URL` in `/opt/jaas/ui/shared/env` to the api VM's **private**
   IP.
3. Open OCI security list / NSG ingress: `80`/`443` from `0.0.0.0/0` on both
   VMs; `22` restricted to your own IP; **no** rule needed between the VMs
   for port 8027/8028 if they're in the same subnet's default security list
   (same-subnet traffic is allowed by default) — otherwise add an ingress
   rule on the api VM's NSG allowing `8027/tcp` from the web VM's private IP
   only.
4. Point DNS: `DOMAIN` → web VM public IP, `API_DOMAIN` → api VM public IP.
5. `systemctl start jaas-ui` (web VM) / `systemctl start jaas-guardrails
   jaas-registry` (api VM) once secrets are filled in.

## GitHub configuration

The deploy SSH keypair was generated for this setup; the **public** half
needs to be passed to both provisioning scripts above. The **private** half
is stored as the `DEPLOY_SSH_KEY` secret in each of the three source repos
(already set — see below).

In **each** of `jaas-ui`, `jaas-skills`, `jaas-guardrails`, once the VMs
exist:

| Name | Kind | Value |
|---|---|---|
| `DEPLOY_SSH_KEY` | secret | the CI deploy private key (already set) |
| `DEPLOY_SSH_USER` | secret | `jaas` |
| `DEPLOY_SSH_HOST_KEY` | secret | `ssh-keyscan <web-vm-ip> && ssh-keyscan <api-vm-ip>` output, both lines |
| `DEPLOYMENT_ENABLED` | **variable** | `true` — flips the deploy job on; leave unset until the VMs and secrets above are ready, so pushes don't fail loudly in the meantime |
| `WEB_VM_HOST` | **variable** | web VM's IP/hostname — only needed in `jaas-ui` |
| `API_VM_HOST` | **variable** | api VM's IP/hostname — only needed in `jaas-skills` and `jaas-guardrails` |

Each source repo's `.github/workflows/deploy.yml` reads its target host from
the `WEB_VM_HOST`/`API_VM_HOST` repo variable above rather than hardcoding
it, so pointing at a new VM later is a variable change, not a code change.

## Rollback

```bash
ssh jaas@<vm> 'ls -1t /opt/jaas/<service>/releases'   # pick an older one
ssh jaas@<vm> "ln -sfn /opt/jaas/<service>/releases/<older> /opt/jaas/<service>/current"
ssh jaas@<vm> 'sudo systemctl restart jaas-<service>'
```
