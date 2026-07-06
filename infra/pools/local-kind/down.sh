#!/usr/bin/env bash
# local-kind down — delete the kind cluster and its kubeconfig.
source "$(dirname "$0")/../../../scripts/lib.sh"
source "$(dirname "$0")/_kind.sh"
KIND="$(ensure_kind)"

log "deleting kind cluster '${CLUSTER}'"
"${KIND}" delete cluster --name "${CLUSTER}" || warn "cluster '${CLUSTER}' was not present"
rm -f "${KUBECONFIG_PATH}"
ok "kind cluster removed"
