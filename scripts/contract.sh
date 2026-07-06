#!/usr/bin/env bash
# contract.sh — run the seam contract (contract.py) against the running
# platform, through the chat proxy (the UI's exact path to the API).
source "$(dirname "$0")/lib.sh"
require python3; require curl

PORT="${PORT:-8080}"
k cluster-info >/dev/null 2>&1 || die "no running cluster — run 'make up' first"

banner "contract — pool=${POOL} serving=${SERVING}"
k -n "${NAMESPACE}" port-forward svc/chat "${PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
  curl -fsS "http://localhost:${PORT}/v1/models" >/dev/null 2>&1 && break
  sleep 0.5
done

python3 "${ROOT}/scripts/contract.py" "http://localhost:${PORT}"
