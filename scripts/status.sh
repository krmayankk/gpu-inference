#!/usr/bin/env bash
# status.sh — what is running right now on POOL.
source "$(dirname "$0")/lib.sh"

banner "status — pool=${POOL}"
if [[ ! -f "${KUBECONFIG_PATH}" ]] || ! k cluster-info >/dev/null 2>&1; then
  dim "nothing running (no reachable cluster for pool '${POOL}')"
  exit 0
fi

k -n "${NAMESPACE}" get deploy,svc,pods 2>/dev/null || dim "namespace '${NAMESPACE}' not present yet"
