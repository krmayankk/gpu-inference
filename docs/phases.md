# Phase Ladder

Each phase is independently **build → test → demo → tear down clean**. Money is spent only
while a phase is running; every phase returns the account to zero residual cost. A phase is
"done" when its demo runs end-to-end *and* `make down` verifies zero orphaned resources.

| Phase | Cost footprint | Status |
|---|---|---|
| 0 — Scaffolding | ~$0 (CPU dry-run) | not started |
| 1 — Single-GPU modern inference | ~$0.3–1/hr | not started |
| 2 — Distributed inference | a few $/hr | not started |
| 3 — GitOps + chat UI | as ph.2 | not started |
| 4 — Autoscaling + cost autonomy | scales to 0 idle | not started |
| 5 — Multi-cloud H100/H200 burst | burst only | not started |
| 6 — CRD-driven infra + fleet autonomy | mgmt cluster only | not started |

---

## Phase 0 — Scaffolding (no GPU cost)

**Build.** Repo structure; `Makefile` with `up`/`down`; Terraform skeleton + remote state
backend (S3/R2 + lock); weights-cache bucket/volume; `sentinel.yml` + `CLAUDE.md` wiring
sentinel as the PR gate; teardown script that enumerates and verifies zero residual resources.

**Test.** `make up` provisions a CPU-only cluster; `make down` proves zero orphans. Sentinel
reviews a trivial PR.

**Demo.** "One command builds and destroys the whole control plane, leaving nothing."

**Tear down.** Inherent — this phase *is* the lifecycle proof.

---

## Phase 1 — Single-GPU modern inference

**Build.** Bring up K8s on RunPod (validate native Instant Cluster K8s vs k3s — ADR-0003);
install the GPU Operator; deploy vLLM serving a 7–14B model on an RTX 4090 (FP8); DCGM →
Prometheus → Grafana.

**Test.** Hit the OpenAI-compatible endpoint; confirm FP8 path; read tokens/sec and GPU
telemetry in Grafana.

**Demo.** Modern inference on the cheapest credible footprint; the portability seam exists
from day one.

**Tear down.** `make down`; weights remain cached in the network volume for next time.

---

## Phase 2 — Distributed inference

**Build.** KubeRay RayCluster; vLLM with `tensor-parallel-size` across multiple GPUs (and a
pipeline-parallel variant across nodes for the learning value); a 32–72B INT4/FP8 model.

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
