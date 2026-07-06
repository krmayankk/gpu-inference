#!/usr/bin/env bash
# aws pool up — provision EKS (system + GPU node groups) and emit:
#   - ${KUBECONFIG_PATH}    isolated kubeconfig
#   - ${POOL_CONTEXT_PATH}  seam data for the platform layer (weights bucket,
#                           region) — published as the pool-context ConfigMap
#                           by scripts/up.sh so platform/ stays pool-agnostic.
#
# SPENDS MONEY — guarded by CONFIRM_SPEND=1. Requires `make bootstrap` once.
source "$(dirname "$0")/../../../scripts/lib.sh"
require terraform; require aws; require jq

TF_DIR="$(dirname "$0")"

if [[ "${CONFIRM_SPEND:-0}" != "1" ]]; then
  die "pool 'aws' provisions paid GPU infrastructure (~\$1.15/hr for l4). Re-run with CONFIRM_SPEND=1."
fi

BOOT="${ROOT}/infra/bootstrap"
bucket="$(terraform -chdir="${BOOT}" output -raw state_bucket 2>/dev/null || true)"
table="$(terraform -chdir="${BOOT}" output -raw lock_table 2>/dev/null || true)"
[[ -n "${bucket}" && -n "${table}" ]] || die "remote state not found — run 'make bootstrap' first"

# Backend region = where the state bucket lives (bootstrap's region), pinned
# independently of the cluster region — moving the cluster must never re-point
# the backend.
backend_region="$(terraform -chdir="${BOOT}" output -raw region)"

log "terraform init/apply (EKS system+gpu, profile=${GPU})"
terraform -chdir="${TF_DIR}" init -reconfigure \
  -backend-config="bucket=${bucket}" \
  -backend-config="dynamodb_table=${table}" \
  -backend-config="region=${backend_region}"
terraform -chdir="${TF_DIR}" apply -auto-approve -var "gpu_profile=${GPU}"

name="$(terraform -chdir="${TF_DIR}" output -raw cluster_name)"
region="$(terraform -chdir="${TF_DIR}" output -raw region)"
weights="$(terraform -chdir="${TF_DIR}" output -raw weights_bucket)"

log "writing kubeconfig -> ${KUBECONFIG_PATH}"
KUBECONFIG="${KUBECONFIG_PATH}" aws eks update-kubeconfig --name "${name}" --region "${region}" >/dev/null

# --- TTL dead-man's switch (ADR-0006) --------------------------------------
# Re-armed on every `make up`: the GPU ASG is scheduled to zero ttl_hours from
# now, so an abandoned demo stops burning GPU money by itself. Idempotent PUT.
ttl="$(terraform -chdir="${TF_DIR}" output -raw ttl_hours)"
ng="$(terraform -chdir="${TF_DIR}" output -raw gpu_node_group)"
asg="$(aws eks describe-nodegroup --cluster-name "${name}" --nodegroup-name "${ng##*:}" \
  --region "${region}" --query 'nodegroup.resources.autoScalingGroups[0].name' --output text)"
if [[ -n "${asg}" && "${asg}" != "None" ]]; then
  aws autoscaling put-scheduled-update-group-action \
    --auto-scaling-group-name "${asg}" \
    --scheduled-action-name gpu-ttl-zero \
    --start-time "$(date -u -d "+${ttl} hours" +%Y-%m-%dT%H:%M:%SZ)" \
    --min-size 0 --max-size 0 --desired-capacity 0 \
    --region "${region}"
  ok "TTL armed: GPU nodes scale to zero at +${ttl}h unless re-upped"
else
  warn "could not resolve GPU ASG — TTL switch NOT armed; do not walk away from this cluster"
fi

# Seam data the invariant layer may consume (via the pool-context ConfigMap).
cat > "${POOL_CONTEXT_PATH}" <<EOF
WEIGHTS_BUCKET=${weights}
AWS_REGION=${region}
EOF

ok "aws substrate ready (cluster ${name}, ${region}, gpu=${GPU})"
