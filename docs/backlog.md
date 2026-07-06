# Engineering backlog

Debts and lessons carried out of Phase 1 (closed 2026-07-05, commit 782179c).
Each item names its phase home. Nothing here is architectural — Phase 1 ended
with the seam intact; these are edges to sand.

## Correctness / trust
- **Contract must pin backend identity.** `contract.py` passes against ANY
  compliant backend — during Phase 1 a port collision let the local mock
  masquerade as the GPU and the contract "passed". Add an expected-identity
  assertion (`/v1/models` root == the profile's model, owned_by == vllm when
  SERVING=vllm). *Phase 2, first PR.*
- **Per-pool kubeconfig paths.** `.kubeconfig` is shared by all pools; running
  local-kind and aws simultaneously invites cross-talk (and local-kind's
  `down.sh` would delete the EKS kubeconfig). Move to `.kubeconfig-<pool>`;
  `make env` picks by POOL. *Phase 2.*
- **Weights sync duplicates the HF cache** (~2× bytes: `s3 sync` follows
  `snapshots/` symlinks into `blobs/`). Sync blobs + rebuild symlinks, or tar
  the cache. Cosmetic at 7B (~$0.70/mo), real at 70B. *Before Phase 2's big models.*

## Availability / UX
- **`kubectl port-forward` drops SSE streams** — the chat "stall"; refresh
  reconnects. Proper fix is an Ingress/LB with auth. *Phase 3 (public surface).*
- **DCGM 30s collection interval** makes short-query spikes invisible in
  Grafana. Set `dcgmExporter` interval ~5s for demos. *Phase 2, one helm value.*

## Security hardening (deliberate Phase-1 trade-offs)
- **IRSA/Pod Identity** replaces node-role S3 access. *Phase 3.*
- **Private EKS endpoint + bastion/SSM** replaces public API endpoint. *Phase 3.*

## Operational notes (facts, not tasks)
- Quota is the region anchor: G/VT (L-DB2E81BA) = 32 vCPUs in **us-east-1**;
  us-west-2 request PENDING (filed 2026-07-05). 32 vCPUs = 4× g6.2xlarge —
  enough for Phase 2 multi-GPU without a new request (g6.12xlarge = 48 vCPUs
  would need one).
- MFA session pattern for all AWS work: `infra/pools/aws/README.md`.
- Next spin-up prefetches weights from S3 (gateway endpoint, NAT-free) — cold
  start drops from ~25 min to ~15.

## Phase 2 starting points
- KubeRay operator + RayCluster; vLLM TP within a g6.12xlarge (4× L4) or
  PP across g6.2xlarge nodes — decide after measuring single-node TP.
- DRA: NVIDIA driver, ResourceClaims replace `nvidia.com/gpu: N` requests
  (device plugin stays as fallback). MIG demos need A100/H100 → Phase 5.
- Model target: 32B-class INT4/FP8 (Qwen2.5-Coder-32B fits 4× L4 TP=4).
- The t4/l4/h100 profile mechanism is ready for a `l4x4` profile — one
  directory + one gpu_profiles row, per ADR-0003 amendment.
