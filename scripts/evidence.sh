#!/usr/bin/env bash
# evidence.sh — snapshot a LIVE run into a committed, raw evidence bundle.
#
#   make evidence                      # -> docs/runs/<date>-<gpu>/evidence/
#   RUN_DIR=docs/runs/foo make evidence
#
# Read-only: every command is a get/describe/exec-read. Raw output, lightly
# headed, so a reader can trust it was captured, not written. Capture while the
# cluster is up — Kubernetes events expire after ~1h and nothing here can be
# recovered after `make down`. The AWS account id and local paths are redacted.
source "$(dirname "$0")/lib.sh"
require kubectl

RUN_DIR="${RUN_DIR:-${ROOT}/docs/runs/$(date +%F)-${GPU}}"
OUT="${RUN_DIR}/evidence"
mkdir -p "${OUT}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"

# cap <file> <description> <command...> — run, header it, redact, save.
cap() {
  local file="$1" desc="$2"; shift 2
  {
    echo "# ${desc}"
    echo "# captured: $(date -u +%FT%TZ)"
    echo "# \$ $*"
    echo
    "$@" 2>&1 || echo "(exit $?)"
  } | sed "s#${ROOT}#.#g" \
    | if [[ -n "${ACCOUNT_ID}" ]]; then sed "s/${ACCOUNT_ID}/<account-id>/g"; else cat; fi \
    > "${OUT}/${file}"
  ok "${file}"
}

HEAD="$(k -n "${NAMESPACE}" get pod -l ray.io/node-type=head -o name 2>/dev/null | head -1)"
HEAD="${HEAD#pod/}"

banner "evidence -> ${OUT#"${ROOT}/"}"

cap meta.txt "what was deployed" bash -c "
  echo \"git: \$(git -C '${ROOT}' rev-parse HEAD) (\$(git -C '${ROOT}' rev-parse --abbrev-ref HEAD))\"
  echo \"pool=${POOL} gpu=${GPU} namespace=${NAMESPACE}\"
  kubectl --kubeconfig '${KUBECONFIG_PATH}' version 2>/dev/null"
if [[ "${POOL}" == "aws" ]]; then
  cap instances.txt "EC2 instances in this platform (Project tag)" \
    aws ec2 describe-instances --region "${AWS_REGION:-us-east-1}" \
      --filters Name=tag:Project,Values="${PROJECT}" Name=instance-state-name,Values=running \
      --query 'Reservations[].Instances[].[InstanceId,InstanceType,Placement.AvailabilityZone,LaunchTime]' \
      --output table
fi
cap nodes.txt "nodes: type, zone, GPU as seen by GPU Feature Discovery" \
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes -o wide \
    -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone,nvidia.com/gpu.product,nvidia.com/gpu.memory,nvidia.com/gpu.count
cap namespaces.txt "namespaces" k get namespaces
cap helm-releases.txt "installed components (Helm releases)" helm --kubeconfig "${KUBECONFIG_PATH}" list -A
cap pods-all.txt "every pod, every namespace, with node placement" k get pods -A -o wide
cap events.txt "cluster events, oldest first (the boot timeline; expires ~1h)" \
  k get events -A --sort-by=.metadata.creationTimestamp
cap gpu-operator.txt "GPU operator health (ClusterPolicy)" k get clusterpolicy -o wide
cap dra.txt "DRA objects (API present; unused by this profile)" \
  k get deviceclasses,resourceslices,resourceclaims -A

if [[ -n "${HEAD}" ]]; then
  cap raycluster.txt "RayCluster + Ray pods (role labels)" bash -c "
    kubectl --kubeconfig '${KUBECONFIG_PATH}' -n '${NAMESPACE}' get raycluster -o wide
    echo
    kubectl --kubeconfig '${KUBECONFIG_PATH}' -n '${NAMESPACE}' get pods -o wide -L ray.io/node-type,ray.io/group"
  cap ray-status.txt "Ray's view: nodes, GPUs, placement groups" \
    k -n "${NAMESPACE}" exec "${HEAD}" -c ray-head -- ray status
  cap gpu-request.txt "how a worker pod requests its GPU" bash -c "
    kubectl --kubeconfig '${KUBECONFIG_PATH}' -n '${NAMESPACE}' get pod -l ray.io/node-type=worker \
      -o jsonpath='{range .items[0]}resources: {.spec.containers[0].resources}{\"\n\"}nodeSelector: {.spec.nodeSelector}{\"\n\"}tolerations: {.spec.tolerations}{\"\n\"}resourceClaims: {.spec.resourceClaims}{\"\n\"}{end}'"
  # Per-pod: vLLM + Ray processes and the GPU as the container sees it.
  : > "${OUT}/processes-per-pod.txt"; : > "${OUT}/nvidia-smi.txt"
  for p in $(k -n "${NAMESPACE}" get pods -l ray.io/cluster=inference -o name | sort); do
    p="${p#pod/}"
    role="$(k -n "${NAMESPACE}" get pod "${p}" -o jsonpath='{.metadata.labels.ray\.io/node-type}')"
    node="$(k -n "${NAMESPACE}" get pod "${p}" -o jsonpath='{.spec.nodeName}')"
    c="$([[ "${role}" == head ]] && echo ray-head || echo ray-worker)"
    { echo "=== ${p} [${role}] node=${node}"
      k -n "${NAMESPACE}" exec "${p}" -c "${c}" -- ps -eo pid,etime,rss,cmd --sort=-rss 2>&1 \
        | grep -E "PID|vllm|VLLM|ray::|raylet|gcs_server" | grep -v grep | cut -c1-200
      echo; } >> "${OUT}/processes-per-pod.txt"
    { echo "=== ${p} [${role}] node=${node}"
      k -n "${NAMESPACE}" exec "${p}" -c "${c}" -- nvidia-smi 2>&1
      echo; } >> "${OUT}/nvidia-smi.txt"
  done
  ok "processes-per-pod.txt"; ok "nvidia-smi.txt"
  cap vllm-metrics.txt "vLLM Prometheus metrics (vllm:* only)" \
    k -n "${NAMESPACE}" exec "${HEAD}" -c ray-head -- python3 -c \
      "import urllib.request;[print(l) for l in urllib.request.urlopen('http://localhost:8000/metrics').read().decode().splitlines() if l.startswith('vllm:')]"
fi

banner "evidence captured — review, then commit ${OUT#"${ROOT}/"}"
