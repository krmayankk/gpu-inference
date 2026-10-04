#!/usr/bin/env bash
# cache-weights.sh — push the HF cache from the running vLLM pod to S3, so the
# NEXT spin-up prefetches via the S3 gateway endpoint instead of re-downloading
# from Hugging Face through NAT (ADR-0005). Run once after first boot of a new
# model; idempotent (s3 sync).
source "$(dirname "$0")/lib.sh"

[[ "${SERVING}" == "vllm" ]] || die "cache-weights only applies to GPU pools (current serving: ${SERVING})"
k cluster-info >/dev/null 2>&1 || die "no running cluster — run 'make up' first"

banner "cache weights -> S3"
# Single-pod profiles: the Deployment. Ray profiles: the head pod (it carries
# the same cache-sync sidecar over its own weights volume).
if k -n "${NAMESPACE}" get deploy/inference >/dev/null 2>&1; then
  TARGET="deploy/inference"
else
  TARGET="$(k -n "${NAMESPACE}" get pod -l ray.io/node-type=head -o name | head -1)"
  [[ -n "${TARGET}" ]] || die "no inference Deployment or Ray head pod found"
fi
k -n "${NAMESPACE}" exec "${TARGET}" -c cache-sync -- /bin/bash -c '
  set -euo pipefail
  [[ -n "${WEIGHTS_BUCKET:-}" ]] || { echo "no WEIGHTS_BUCKET in pool-context"; exit 1; }
  echo "syncing /cache -> s3://${WEIGHTS_BUCKET}/hf-cache"
  # The HF cache stores each file once in blobs/ and symlinks it from
  # snapshots/. S3 has no symlinks, so a plain sync uploads every file twice
  # (observed: 61.8GB for a 30.9GB model). Upload snapshots/ (symlinks followed
  # -> real files) + refs/, skip blobs/: HF loads from snapshots/ on restore.
  aws s3 sync /cache "s3://${WEIGHTS_BUCKET}/hf-cache" --no-progress --exclude "*/blobs/*"
'
ok "weights cached — next spin-up prefetches from S3 (free via gateway endpoint)"
