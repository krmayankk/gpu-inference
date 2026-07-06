#!/usr/bin/env bash
# aws pool down — destroy the cluster, node groups, VPC, NAT. Everything.
source "$(dirname "$0")/../../../scripts/lib.sh"
require terraform
TF_DIR="$(dirname "$0")"

log "terraform destroy (EKS + node groups + VPC + NAT)"
terraform -chdir="${TF_DIR}" destroy -auto-approve -var "gpu_profile=${GPU}"
rm -f "${KUBECONFIG_PATH}" "${POOL_CONTEXT_PATH}"
ok "aws pool destroyed (verify-zero-orphans runs next)"
