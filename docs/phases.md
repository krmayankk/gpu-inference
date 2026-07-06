# Phase Ladder

Each phase is independently **build → test → demo → tear down clean**. Money is spent only
while a phase is running; every phase returns the account to zero residual cost. A phase is
"done" when its demo runs end-to-end *and* `make down` verifies zero orphaned resources.

| Phase | Cost footprint | Status |
|---|---|---|
| 0 — Scaffolding + $0 chat demo | ~$0 (local kind) | **built** |
| 1 — Single-GPU modern inference (L4, FP8) | ~$1.2/hr while up | **built** (verified live 2026-07-05) |
| 2 — Distributed inference | a few $/hr | not started |
| 3 — GitOps + chat UI | as ph.2 | not started |
| 4 — Autoscaling + cost autonomy | scales to 0 idle | not started |
| 5 — Multi-cloud H100/H200 burst | burst only | not started |
| 6 — CRD-driven infra + fleet autonomy | mgmt cluster only | not started |

---

## Phase 0 — Scaffolding + $0 chat demo (no GPU cost) — **BUILT**

**Build.** Repo structure; `Makefile` as the single control surface (`up`/`demo`/`down`/`verify`);
the `local-kind` pool as the $0 substrate; the invariant `platform/` layer (serving base + Service
`inference` + chat UI); a CPU **mock** overlay that speaks the OpenAI `/v1` API (ADR-0009); the
`aws` Phase-1 pool + Terraform remote-state backend as ready skeletons; `sentinel.yml` +
`CLAUDE.md` wiring Sentinel as the PR gate; `orphans.sh` per pool that verifies zero residual
resources.

**Test.** `make demo` on `local-kind` brings the platform up, does a real chat round-trip through
the OpenAI-compatible endpoint, and (with `TEARDOWN=1`) proves zero orphans. `make lint` builds
every kustomize overlay. Sentinel reviews a trivial PR.

**Demo.** "One command stands up a working ChatGPT-style chat backed by the same manifests that
will run on a GPU — then destroys it, leaving nothing." The seam (ADR-0002/0009) is established
and *demonstrated* from this phase, not just designed.

**Tear down.** `make down` → `verify-zero-orphans` — the lifecycle proof is inherent.

---

## Phase 1 — Single-GPU inference on EKS (L4 direct; quota cleared 2026-07)

**Build.** EKS via the `aws` pool (system node group for the untainted world + one GPU node
group, `AL2023_x86_64_NVIDIA` AMI); NVIDIA GPU Operator with driver/toolkit disabled (the AMI
owns them — the operator contributes device plugin, GFD labels, DCGM); vLLM `v0.24` serving
**Qwen2.5-Coder-7B at hardware FP8 on L4** (`GPU=l4`, ADR-0004 amendment); S3 pull-through
weights cache (prefetch initContainer + `make cache-weights`, NAT-free via gateway endpoint);
DCGM → Prometheus → Grafana (`OBS=1` default on GPU pools) with the PLAN §5 metrics
(`MEM_COPY_UTIL`, `FB_USED`, `GPU_UTIL`, `POWER_USAGE`); **TTL dead-man's switch** zeroing the
GPU ASG after `ttl_hours`.

**Test.** The same `scripts/contract.py` that gates the mock passes against vLLM-on-L4 — the
seam contract holding across substrates IS the phase's test. Plus: tokens/sec and VRAM visible
in Grafana; `make down` → orphan sweep keyed on `Ephemeral=true` (API errors fail the proof —
a blind sweep never reports clean).

**Demo.** The Phase-0 chat website, unchanged, now answering from a real model on a real GPU:
`make up POOL=aws GPU=l4 CONFIRM_SPEND=1` → `make chat`. One diff between $0 mock and CUDA.

**Tear down.** `make down`; weights persist in the S3 cache (60-day lifecycle) for the next
spin-up. Security note for the record: weights-bucket access rides the node role in Phase 1
(single-tenant, ephemeral) — IRSA/Pod Identity is the Phase-3 hardening item.

---

## Phase 2 — Distributed inference

**Build.** KubeRay RayCluster; vLLM with `tensor-parallel-size` across multiple GPUs (and a
pipeline-parallel variant across nodes for the learning value); a 32–72B INT4/FP8 model.

**DRA (Dynamic Resource Allocation)** — the SOTA successor to the device-plugin model Phase 1
uses: GPUs as `ResourceClaim`s with structured parameters (claim by VRAM/arch, dynamic sharing)
via the NVIDIA DRA driver. Phase 2 migrates the serving overlay's `nvidia.com/gpu: N` request to
a claim, keeping the device-plugin path as fallback. Honest scope note: the headline DRA demo —
dynamic MIG partitioning — requires A100/H100-class silicon (L4 has no MIG); that lands with the
Phase-5 burst. Full-GPU claims are demonstrable on L4 here.

**Test.** Throughput vs single-GPU; verify parallelism placement; saturate and measure.

**Demo.** Distributed inference across multiple GPUs; parallelism and placement observable end-to-end.

**Tear down.** `make down`.

---

## Phase 3 — GitOps + ChatGPT-style UI

**Build.** ArgoCD app-of-apps so everything in-cluster is git-synced; Open WebUI or a custom
Next.js chat frontend (streaming, model picker); an agentic layer; conversation persistence to
Postgres (dumped to object storage). Sentinel gates all PRs before sync.

**Test.** End-to-end chat against self-hosted models; AI-gated PR → ArgoCD sync.

**Demo.** A ChatGPT-style site backed entirely by self-hosted open models, delivered through
AI-gated continuous delivery.

**Tear down.** `make down`; conversation history restored on next spin-up.

---

## Phase 4 — Autoscaling + cost autonomy

**Build.** Karpenter (GPU nodes scale 0→N→0); KEDA/HPA (vLLM replicas on request load / queue
depth); the **orphan / cost-drift detector** as the operator agent's first job → opens cleanup
PRs.

**Test.** Load test drives scale-up; idle drives scale-to-zero; inject a leaked resource and
watch the operator open a cleanup PR.

**Demo.** Self-managing infra: a cost graph that climbs under load and returns to zero,
plus an agent-authored cleanup PR.

**Tear down.** `make down`.

---

## Phase 5 — Multi-cloud H100/H200 burst

**Build.** Add a RunPod/Lambda H100/H200 Instant Cluster pool module; register it to the same
control plane; run the *same* manifests with only `tensor-parallel-size` + pool changed.

**Test.** Same model on dev GPU vs H100 cluster; capture latency/throughput/cost side-by-side.

**Demo.** The portability thesis, proven live: cost is the only difference between a
consumer GPU and an 8×H100 NVLink cluster.

**Tear down.** `make down` on the burst cluster — the expensive thing never lingers.

---

## Phase 6 — CRD-driven infra + fleet autonomy

**Build.** A small management cluster runs Crossplane + ArgoCD; GPU cluster lifecycle becomes
git-synced CRDs; the operator agent owns fleet-wide drift and remediation.

**Test.** Create/destroy a GPU cluster via a git commit; introduce drift and watch the operator
reconcile via PR.

**Demo.** Everything declarative; the system manages itself — the capstone.

**Tear down.** Tear down the management cluster; git holds the entire system.
