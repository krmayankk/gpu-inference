#!/usr/bin/env bash
# demo.sh — the phase showcase: bring it up, prove the seam contract holds,
# then a human-readable chat round-trip. TEARDOWN=1 destroys-and-verifies
# afterwards (the "leaves nothing behind" proof).
source "$(dirname "$0")/lib.sh"
require curl; require python3

PORT="${PORT:-8080}"

"${ROOT}/scripts/up.sh"

# Contract first: machine-checked proof this backend honors the seam.
"${ROOT}/scripts/contract.sh"

banner "demo — chat round-trip through Service inference (/v1)"
k -n "${NAMESPACE}" port-forward svc/chat "${PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -fsS "http://localhost:${PORT}/v1/models" >/dev/null 2>&1 && break
  sleep 0.5
done

log "POST /v1/chat/completions"
reply="$(curl -fsS "http://localhost:${PORT}/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d '{"model":"gpu-inference","max_tokens":120,"messages":[{"role":"user","content":"In one line: what are you and what proves the portability thesis?"}]}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"])')"

banner "assistant replied"
printf '  %s\n\n' "${reply}"

ok "end-to-end chat works: browser/UI -> chat -> Service inference -> ${SERVING} pod"
dim "open the UI:  make chat   (http://localhost:${PORT})"

if [[ "${TEARDOWN:-0}" == "1" ]]; then
  kill "${PF_PID}" 2>/dev/null || true; trap - EXIT
  "${ROOT}/scripts/down.sh"
  banner "demo complete — built, contract-proven, demonstrated, torn down to zero"
else
  dim "when done:    make down   (destroys everything, proves zero orphans)"
fi
