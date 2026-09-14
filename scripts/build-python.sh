#!/usr/bin/env bash
# Packages a Python service's (jaas-skills "registry", or jaas-guardrails)
# source tree as a tarball. Deliberately ships source + uv.lock rather than
# a prebuilt venv: the target VM runs `uv sync --frozen` itself on deploy
# (see deploy.sh), so the venv is always built for the VM's own platform —
# no cross-arch wheel concerns even if the CI runner and VM ever diverge.
set -euo pipefail

service="$1"   # registry | guardrails

tar -czf artifact.tar.gz \
  --exclude='.git' \
  --exclude='.venv' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  .

echo "Packaged $service source as artifact.tar.gz"
