#!/usr/bin/env bash
# cache-weights.sh — push the HF cache from the running vLLM pod to S3, so the
# NEXT spin-up prefetches via the S3 gateway endpoint instead of re-downloading
# from Hugging Face through NAT (ADR-0005). Run once after first boot of a new
# model; idempotent (s3 sync).
source "$(dirname "$0")/lib.sh"

[[ "${SERVING}" == "vllm" ]] || die "cache-weights only applies to GPU pools (current serving: ${SERVING})"
k cluster-info >/dev/null 2>&1 || die "no running cluster — run 'make up' first"

banner "cache weights -> S3"
k -n "${NAMESPACE}" exec deploy/inference -c cache-sync -- /bin/bash -c '
  set -euo pipefail
  [[ -n "${WEIGHTS_BUCKET:-}" ]] || { echo "no WEIGHTS_BUCKET in pool-context"; exit 1; }
  echo "syncing /cache -> s3://${WEIGHTS_BUCKET}/hf-cache"
  aws s3 sync /cache "s3://${WEIGHTS_BUCKET}/hf-cache" --no-progress
'
ok "weights cached — next spin-up prefetches from S3 (free via gateway endpoint)"
