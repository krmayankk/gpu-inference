# Autonomous Multi-Cloud Inference Platform

A production-shaped, fully ephemeral Kubernetes platform for serving open-weight LLMs
(Qwen-2.5-Coder, DeepSeek, Kimi-class) across heterogeneous GPU providers — built to be
stood up, tested, demonstrated, and torn down to **zero residual cost** on demand, and to
manage and heal itself through AI agents wired into the GitOps pipeline.

The design goal that drives every decision: **the same stack runs identically on a $0.34/hr
consumer GPU and an 8×H100 cluster — only the node pool and the parallelism parameters
change.** Cost is the only variable; the architecture is invariant.

---

## 1. Design principles

1. **Ephemeral by default.** Nothing is hand-built and nothing is left running. `make up`
   creates the entire platform from git; `make down` removes 100% of it and verifies zero
   orphaned resources. The only state that survives is in git and object storage.
2. **The GPU is a commodity slot.** Kubernetes + the NVIDIA GPU Operator are the invariant.
   The GPU node pool is the *only* provider- or hardware-specific layer, isolated behind a
   thin swappable module. This is what makes the platform port to H100 "blindly."
3. **Cost hygiene is a feature, not an afterthought.** TTL auto-termination, scale-to-zero,
   weights cached outside the GPU lifecycle, and automated orphan detection are first-class.
4. **GitOps is the only mutation path.** Every change to the running system is a merged PR.
   AI agents review, gate, and increasingly *author* those PRs.
5. **Self-managing over self-built.** The platform's endgame is an operator agent that
   detects drift, cost leaks, and incidents and opens remediation PRs without a human.

## 2. The portability seam

```
INVARIANT  (byte-identical T4 → 4090 → L40S → A100 → H100):
  NVIDIA GPU Operator     (nvidia.com/gpu device plugin, DCGM telemetry, container toolkit)
  KubeRay operator        (RayCluster CRDs for distributed serving/training)
  vLLM serving manifests  (OpenAI-compatible endpoints)
  ArgoCD app-of-apps      (GitOps for everything in-cluster)
  Prometheus / Grafana    (observability)
  Chat UI + agentic layer

SWAPPABLE  (the only seam):
  infra/pools/<runpod|aws|lambda|gke>/   ← provisions GPU nodes, emits a kubeconfig
  values/<gpu>.yaml                      ← model id, tensor/pipeline-parallel size, replicas
```

Switching substrate = apply a different pool module + change `tensor-parallel-size`.
Because of this seam, the choice of starting provider is **not a one-way door** — it is
deliberately the cheapest thing that unblocks us today.

## 3. Substrate strategy

| Layer | Choice | Why |
|---|---|---|
| **Dev / Phase 1–4** | **RunPod** (GPU pods + network volumes; Instant Clusters for multi-node) | Modern GPUs by the hour (4090/L40S/A100/H100), zero egress on weights, no quota wait. AWS GPU quota is gated to a single instance type today — RunPod unblocks immediately. |
| **Burst / Phase 5** | RunPod / Lambda **H100 / H200** Instant Cluster, NVLink fabric | Proves the H100 portability thesis live: same manifests, only parallelism + pool change. |
| **Later (optional)** | **AWS EKS** or **GKE** added as a pool module | When a managed control plane is preferred. Drop-in, not a rewrite — by design. |

> The platform is provider-agnostic on purpose. Being quota-blocked on AWS doesn't slow us
> down; it *validates the thesis* — we start on RunPod and AWS becomes a later pool module.

## 4. State that survives teardown

| State | Home | Reason |
|---|---|---|
| All manifests / IaC / config | git | single source of truth; the platform rebuilds from it |
| Model weights cache | RunPod network volume / S3 / R2 | avoids re-downloading 100s of GB on every spin-up — the biggest single cost-hygiene win |
| Conversation history (chat) | Postgres dumps in object storage | survives cluster teardown; restored on next `make up` |

Everything else — clusters, ArgoCD, Prometheus, GPU Operator, vLLM, the UI — is ephemeral
and reconstructed identically from git on each spin-up.

## 5. IaC maturity path (TF → GitOps → CRD-driven)

There is a bootstrap paradox: CRDs need a cluster to apply them, so something imperative
always lights the first match. The platform matures along that reality:

- **A — Terraform bootstrap.** TF provisions the cluster shell + GPU pool. `terraform destroy` is clean.
- **B — GitOps for apps.** ArgoCD app-of-apps owns everything inside the cluster; TF shrinks to the shell.
- **C — CRD-driven infra (Crossplane).** A small management cluster runs Crossplane + ArgoCD;
  GPU clusters themselves become git-synced CRDs. "Create an H100 cluster" becomes a git commit.

Autoscaling is two independent layers: **Karpenter / Cluster Autoscaler** (nodes scale to
zero when idle — the cost guarantee) and **KEDA / HPA** (vLLM replicas on request load).

## 6. AI-driven operation

- **Phase 0+ — Reviewer.** [Sentinel](../sentinel) runs on every PR via GitHub Actions,
  reading `CLAUDE.md` to enforce infra conventions (e.g. a vLLM parallelism change must come
  with the matching GPU node-pool change). Only PRs it gates merge → ArgoCD syncs.
- **Phase 4+ — Operator.** An agent watches the running platform for drift, orphaned cloud
  resources, and cost anomalies, and opens remediation PRs. The first autonomy slice is
  **orphan / cost-drift detection** — the same mechanism that protects the budget proves the
  self-management story.

## 7. Roadmap

The platform is built as an independently demoable ladder — each phase spins up, is tested,
demonstrated, and torn down clean. See [`docs/phases.md`](docs/phases.md) for the full ladder
and [`docs/decisions.md`](docs/decisions.md) for the locked design decisions.

| Phase | Outcome |
|---|---|
| 0 | Scaffolding: repo, `make up`/`down`, state backend, sentinel PR-gate, teardown-verifies-zero-orphans |
| 1 | Single-GPU modern inference (vLLM, FP8) on RunPod, end-to-end with observability |
| 2 | Distributed inference (KubeRay, tensor/pipeline-parallel, larger models) |
| 3 | GitOps + ChatGPT-style UI + agentic layer (the visible product surface) |
| 4 | Autoscaling (Karpenter + KEDA) + cost-autonomy operator |
| 5 | Multi-cloud H100/H200 burst — portability thesis proven live |
| 6 | CRD-driven infra (Crossplane) + fleet-wide self-management |
