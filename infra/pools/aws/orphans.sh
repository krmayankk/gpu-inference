#!/usr/bin/env bash
# aws orphans — the cost guarantee's teeth. Prove nothing EPHEMERAL survives
# teardown, plus belt-and-suspenders checks on the leak-prone types that can
# escape tagging (EBS, EIP, NAT, LB).
#
# Two properties a proof tool must have:
#   1. It keys on Ephemeral=true — the sanctioned persistent resources (state
#      backend, weights cache; tagged Ephemeral=false) are NOT orphans.
#   2. An API error is a FAILED PROOF, never a clean verdict. A sweep that
#      cannot see does not get to say "zero".
# Exit 0 = proven clean; non-zero = orphans found OR proof impossible.
source "$(dirname "$0")/../../../scripts/lib.sh"
require aws; require jq
REGION="${AWS_REGION:-us-east-1}"  # cluster region (quota home)
found=0

# query <label> <aws args...> — runs the check; treats API failure as fatal.
query() {
  local label="$1"; shift
  local out
  if ! out="$(aws "$@" --region "${REGION}" --output text 2>&1)"; then
    die "orphan sweep BLIND on '${label}' (${out%%$'\n'*}) — cannot prove zero, failing"
  fi
  if [[ -n "${out}" && "${out}" != "0" && "${out}" != "None" ]]; then
    warn "orphan ${label}: ${out}"; found=1
  fi
}

# The tagging index is eventually consistent and keeps listing resources that
# are already gone or in AWS-managed death states (NAT 'deleted', KMS
# 'PendingDeletion' — a mandatory 7–30 day window, non-billing). Counting those
# as orphans makes the proof cry wolf after every clean teardown, which is
# nearly as corrosive as lying clean. So: the tag sweep finds candidates, then
# each ARN is resolved to LIVE or DYING/GONE; only live ones fail the proof.
log "tag sweep: Project=${PROJECT} AND Ephemeral=true (liveness-resolved)"
arns="$(aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Project,Values=${PROJECT}" "Key=Ephemeral,Values=true" \
  --region "${REGION}" --query 'ResourceTagMappingList[].ResourceARN' --output text 2>&1)" \
  || die "orphan sweep BLIND on tag query (${arns%%$'\n'*}) — cannot prove zero, failing"

for arn in ${arns}; do
  id="${arn##*/}"
  live="unknown"
  case "${arn}" in
    *:security-group/*)
      aws ec2 describe-security-groups --group-ids "${id}" --region "${REGION}" \
        >/dev/null 2>&1 && live="yes" || live="gone" ;;
    *:vpc-endpoint/*)
      st="$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "${id}" --region "${REGION}" \
        --query 'VpcEndpoints[0].State' --output text 2>/dev/null || echo gone)"
      [[ "${st}" == "available" || "${st}" == "pending" ]] && live="yes" || live="gone" ;;
    *:natgateway/*)
      st="$(aws ec2 describe-nat-gateways --nat-gateway-ids "${id}" --region "${REGION}" \
        --query 'NatGateways[0].State' --output text 2>/dev/null || echo gone)"
      [[ "${st}" == "available" || "${st}" == "pending" ]] && live="yes" || live="gone" ;;
    *:kms:*)
      st="$(aws kms describe-key --key-id "${id}" --region "${REGION}" \
        --query 'KeyMetadata.KeyState' --output text 2>/dev/null || echo gone)"
      [[ "${st}" == "PendingDeletion" || "${st}" == "gone" ]] && live="gone" || live="yes" ;;
    *:instance/*)
      st="$(aws ec2 describe-instances --instance-ids "${id}" --region "${REGION}" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo gone)"
      # 'None': the ID no longer resolves at all (purged past 'terminated').
      [[ "${st}" == "terminated" || "${st}" == "shutting-down" || "${st}" == "gone" || "${st}" == "None" ]] \
        && live="gone" || live="yes" ;;
    *:volume/*)
      st="$(aws ec2 describe-volumes --volume-ids "${id}" --region "${REGION}" \
        --query 'Volumes[0].State' --output text 2>/dev/null || echo gone)"
      # 'available' (unattached) IS a leak — that's the classic orphaned EBS.
      [[ "${st}" == "gone" ]] && live="gone" || live="yes" ;;
    *:network-interface/*)
      aws ec2 describe-network-interfaces --network-interface-ids "${id}" \
        --region "${REGION}" >/dev/null 2>&1 && live="yes" || live="gone" ;;
    *)
      # Unknown type: refuse to guess — treat as live so a human looks at it.
      live="yes" ;;
  esac
  if [[ "${live}" == "yes" ]]; then
    warn "orphan (live): ${arn}"; found=1
  else
    dim "ignoring dying/ghost: ${arn}"
  fi
done

query "available EBS volumes" ec2 describe-volumes \
  --filters Name=tag:Project,Values="${PROJECT}" Name=status,Values=available \
  --query 'length(Volumes)'

query "unassociated Elastic IPs" ec2 describe-addresses \
  --filters Name=tag:Project,Values="${PROJECT}" \
  --query "length(Addresses[?AssociationId==null])"

query "NAT gateways" ec2 describe-nat-gateways \
  --filter Name=tag:Project,Values="${PROJECT}" Name=state,Values=available,pending \
  --query 'length(NatGateways)'

query "load balancers (elbv2)" elbv2 describe-load-balancers \
  --query 'length(LoadBalancers)'

exit "${found}"
