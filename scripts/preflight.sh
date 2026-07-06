#!/usr/bin/env bash
# preflight.sh — verify tooling for the selected POOL before spending time (or money).
source "$(dirname "$0")/lib.sh"

banner "preflight — pool=${POOL} serving=${SERVING}"
require kubectl "install kubectl: https://kubernetes.io/docs/tasks/tools/"

# Pool-specific preflight (docker+kind for local, terraform+aws for cloud).
if [[ -x "${POOL_DIR}/preflight.sh" ]]; then
  "${POOL_DIR}/preflight.sh"
else
  warn "pool '${POOL}' has no preflight hook — skipping pool-specific checks"
fi

ok "preflight passed"
