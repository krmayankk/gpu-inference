#!/usr/bin/env bash
# local-kind orphans — prove the local substrate owns nothing after teardown.
# Exit 0 = clean; non-zero = orphans found (down.sh turns that into a failure).
source "$(dirname "$0")/../../../scripts/lib.sh"
source "$(dirname "$0")/_kind.sh"
KIND="$(ensure_kind)"
found=0

# 1. no kind cluster by our name
if "${KIND}" get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  warn "orphan: kind cluster '${CLUSTER}' still exists"; found=1
fi

# 2. no docker containers tagged as our kind cluster's nodes
if command -v docker >/dev/null 2>&1; then
  leftovers="$(docker ps -aq --filter "label=io.x-k8s.kind.cluster=${CLUSTER}" 2>/dev/null || true)"
  if [[ -n "${leftovers}" ]]; then
    warn "orphan: docker containers for cluster '${CLUSTER}': ${leftovers}"; found=1
  fi
fi

# 3. no leftover kubeconfig
if [[ -f "${KUBECONFIG_PATH}" ]]; then
  warn "orphan: kubeconfig still present at ${KUBECONFIG_PATH}"; found=1
fi

exit "${found}"
