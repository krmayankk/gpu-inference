#!/usr/bin/env bash
# local-kind up — create the kind cluster and emit ${KUBECONFIG_PATH}.
# This is the $0 substrate (ADR-0009): CPU-only, no cloud, no GPU. It exists to
# prove the invariant layer (Service/API contract, chat UI, lifecycle) before a
# cent is spent. The GPU pools (aws, ...) are drop-in replacements.
source "$(dirname "$0")/../../../scripts/lib.sh"
source "$(dirname "$0")/_kind.sh"
KIND="$(ensure_kind)"

if "${KIND}" get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  log "kind cluster '${CLUSTER}' already exists — reusing"
else
  log "creating kind cluster '${CLUSTER}'"
  "${KIND}" create cluster --name "${CLUSTER}" --wait 120s
fi

# Write an isolated kubeconfig so we never touch the caller's default context.
"${KIND}" export kubeconfig --name "${CLUSTER}" --kubeconfig "${KUBECONFIG_PATH}"
ok "kind cluster ready; kubeconfig at ${KUBECONFIG_PATH}"
