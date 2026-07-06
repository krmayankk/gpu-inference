#!/usr/bin/env bash
# up.sh — bring the whole platform up on POOL, from nothing.
#
#   1. pool 'up'      provisions the substrate, writes ${KUBECONFIG_PATH}
#                     (and ${POOL_CONTEXT_PATH} on cloud pools)
#   2. gpu operator   invariant on every GPU-capable pool (device plugin, GFD
#                     labels, DCGM); skipped where there is no GPU to operate
#   3. observability  kube-prometheus-stack when OBS=1 (default on GPU pools)
#   4. serving+chat   the invariant layer — identical on every pool; only the
#                     SERVING overlay and GPU profile differ
source "$(dirname "$0")/lib.sh"

"${ROOT}/scripts/preflight.sh"

banner "up — pool=${POOL} gpu=${GPU} serving=${SERVING} obs=${OBS}"

# --- 1. substrate (the only provider-specific step) ------------------------
pool_hook up
[[ -f "${KUBECONFIG_PATH}" ]] || die "pool '${POOL}' up did not produce a kubeconfig at ${KUBECONFIG_PATH}"
k cluster-info >/dev/null 2>&1 || die "cluster is not reachable via ${KUBECONFIG_PATH}"
ok "substrate ready"

# --- 2. observability (before the operator, so its ServiceMonitor CRD exists)
if [[ "${OBS}" == "1" ]]; then
  require helm
  log "kube-prometheus-stack (Prometheus + Grafana)"
  helm --kubeconfig "${KUBECONFIG_PATH}" repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm --kubeconfig "${KUBECONFIG_PATH}" repo update >/dev/null
  helm --kubeconfig "${KUBECONFIG_PATH}" upgrade --install obs \
    prometheus-community/kube-prometheus-stack \
    --namespace observability --create-namespace \
    -f "${ROOT}/platform/observability/kube-prometheus-values.yaml" \
    --wait --timeout 10m
fi

# --- 3. GPU operator (invariant wherever a GPU exists; PLAN §2) -------------
if [[ "${GPU_CAPABLE}" == "1" ]]; then
  require helm
  log "NVIDIA GPU Operator (device plugin, GFD, DCGM; driver+toolkit from AMI)"
  helm --kubeconfig "${KUBECONFIG_PATH}" repo add nvidia \
    https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
  helm --kubeconfig "${KUBECONFIG_PATH}" repo update >/dev/null
  # AL2023 NVIDIA AMIs ship the driver and container toolkit — the operator
  # must not manage them. It contributes the device plugin, GFD labels, DCGM.
  helm --kubeconfig "${KUBECONFIG_PATH}" upgrade --install gpu-operator \
    nvidia/gpu-operator \
    --namespace gpu-operator --create-namespace \
    --set driver.enabled=false \
    --set toolkit.enabled=false \
    --set dcgmExporter.serviceMonitor.enabled="$([[ "${OBS}" == "1" ]] && echo true || echo false)" \
    --wait --timeout 10m
fi

# --- 4. platform (invariant across all pools) ------------------------------
log "namespace ${NAMESPACE}"
k create namespace "${NAMESPACE}" --dry-run=client -o yaml | k apply -f - >/dev/null

# Publish pool seam data (weights bucket, region) where the serving layer can
# consume it without knowing which pool produced it. Empty on local pools.
log "pool-context ConfigMap"
if [[ -f "${POOL_CONTEXT_PATH}" ]]; then
  k -n "${NAMESPACE}" create configmap pool-context \
    --from-env-file="${POOL_CONTEXT_PATH}" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
else
  k -n "${NAMESPACE}" create configmap pool-context \
    --dry-run=client -o yaml | k apply -f - >/dev/null
fi

log "serving (${SERVING}$([[ "${SERVING}" == "vllm" ]] && echo ", gpu=${GPU}"))"
if [[ "${SERVING}" == "vllm" ]]; then
  # Per-GPU kustomization: the single source of truth for model/quant/TP knobs.
  k apply -k "${ROOT}/platform/serving/gpus/${GPU}" >/dev/null
else
  k apply -k "${ROOT}/platform/serving/overlays/mock" >/dev/null
fi

log "chat UI"
k apply -k "${ROOT}/platform/chat" >/dev/null

log "waiting for rollout"
# vLLM cold start = image pull (~10GB) + weight fetch; give it real time.
INFER_TIMEOUT="$([[ "${SERVING}" == "vllm" ]] && echo 1800s || echo 240s)"
k -n "${NAMESPACE}" rollout status deploy/inference --timeout="${INFER_TIMEOUT}"
k -n "${NAMESPACE}" rollout status deploy/chat --timeout=120s

banner "platform is up"
dim "serving : ${SERVING}  (Service inference:8000, OpenAI-compatible /v1)"
[[ "${SERVING}" == "vllm" ]] && dim "cache   : make cache-weights   # push freshly-downloaded weights to S3 for fast next boot"
[[ "${OBS}" == "1" ]] && dim "grafana : make grafana             # port-forward Grafana (DCGM dashboards)"
dim "reach it: make chat                # chat UI at http://localhost:8080"
dim "teardown: make down                # destroy everything, prove zero orphans"
ok "up complete"
