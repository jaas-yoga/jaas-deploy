#!/usr/bin/env bash
# Ships artifact.tar.gz (built by build-node.sh or build-python.sh, in the
# current directory) to the target VM, unpacks it into a timestamped
# release directory, points a `current` symlink at it, and restarts the
# matching systemd unit. Keeps the last 5 releases for quick rollback
# (`ln -sfn releases/<older-one> current && sudo systemctl restart jaas-<service>`).
set -euo pipefail

service="$1"    # ui | registry | guardrails
host="$2"
user="$3"
sha="${GITHUB_SHA:-unknown}"

remote_base="/opt/jaas/${service}"
release="release-$(date -u +%Y%m%d%H%M%S)-${sha:0:7}"

ssh "${user}@${host}" "mkdir -p '${remote_base}/releases/${release}'"
scp artifact.tar.gz "${user}@${host}:${remote_base}/releases/${release}/artifact.tar.gz"

# shellcheck disable=SC2087
ssh "${user}@${host}" bash -s -- "$service" "$remote_base" "$release" <<'REMOTE'
set -euo pipefail
service="$1"
remote_base="$2"
release="$3"
release_dir="${remote_base}/releases/${release}"

cd "$release_dir"
tar -xzf artifact.tar.gz
rm -f artifact.tar.gz

case "$service" in
  registry|guardrails)
    # Rebuilds the venv on the VM itself from the shipped uv.lock — matches
    # this VM's own platform exactly, so no wheel built elsewhere is ever
    # trusted as-is. See build-python.sh for why this happens here, not in CI.
    uv sync --frozen
    ;;
esac

ln -sfn "$release_dir" "${remote_base}/current"
sudo systemctl restart "jaas-${service}"
sudo systemctl --no-pager --lines=5 status "jaas-${service}"

# Prune all but the 5 most recent releases.
cd "${remote_base}/releases"
ls -1t | tail -n +6 | xargs -r rm -rf
REMOTE
