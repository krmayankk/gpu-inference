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
| **Dev / Phase 1–3** | **AWS EKS + g4dn.2xlarge (T4 16GB)** | Available now; the entire K8s + GPU Operator + KubeRay + vLLM stack is validated here. Known limitation: T4 is Turing-arch, no hardware FP8, 16GB caps single-GPU model size to ~13B INT4. Accepted — the K8s layer is identical to what runs on H100. |
| **Dev / Phase 1–3 upgrade** | **AWS EKS + g6.2xlarge (L4 24GB)** | Target once quota clears. Ada Lovelace, hardware FP8, 24GB. Unlocks FP8 serving paths and larger models without any manifest change — only the node group swaps. |
| **Distributed / Phase 2+** | **g4dn.12xlarge (4×T4) or g6.12xlarge (4×L4)** for multi-GPU within-node TP | Tensor parallelism requires NVLink-equivalent bandwidth; within-node via PCIe is the EKS-native path before H100 NVLink burst. |
| **H100/H200 burst / Phase 5** | **Lambda Labs or CoreWeave H100 Instant Cluster** | 8×H100 SXM (NVLink) — same manifests, `tensor-parallel-size 8`, pool module swap. Proves the portability thesis under real NVLink topology. |
| **Later (optional)** | **GKE** pool module | If a second managed-K8s provider is wanted. Drop-in by design. |

> RunPod's Instant Clusters are Slurm-based and explicitly incompatible with Kubernetes.
> It can serve as a burst target via the Kubernetes virtual-kubelet adapter (Phase 5+)
> but is not a K8s control plane you operate. EKS is the primary K8s substrate.

## 4. State that survives teardown

| State | Home | Reason |
|---|---|---|
| All manifests / IaC / config | git | single source of truth; the platform rebuilds from it |
| Model weights cache | S3 (mounted via Mountpoint or copied to PV on spin-up) | avoids re-downloading 100s of GB on every spin-up — the biggest single cost-hygiene win |
| Conversation history (chat) | Postgres dumps in S3 | survives cluster teardown; restored on next `make up` |

Everything else — clusters, ArgoCD, Prometheus, GPU Operator, vLLM, the UI — is ephemeral
and reconstructed identically from git on each spin-up.

## 5. Inference architecture

Understanding inference at the operational level is what drives the K8s design choices.

### Prefill vs decode — two different bottlenecks

A single inference request has two phases with fundamentally different resource profiles:

- **Prefill** — process the full prompt in parallel. Compute-bound. Benefits from large batch
  sizes and high SM utilization. Latency scales with prompt length and model FLOP count.
- **Decode** — autoregressive token generation, one token at a time. **Memory-bandwidth-bound**,
  not compute-bound. Throughput is limited by how fast the GPU can read KV cache + weights,
  not by arithmetic capacity. This is why a T4 (300 GB/s) underperforms an H100 (3.35 TB/s)
  on decode far more than the FLOP difference implies.

vLLM's **continuous batching** (iteration-level scheduling) addresses the decode bottleneck by
batching decode steps across many concurrent requests — keeping memory bandwidth saturated rather
than waiting for a single request to finish. This is the key primitive that makes serving
efficient under real traffic.

### KV cache — the real memory constraint

The KV cache stores attention keys and values for every token in every active request across
every layer. At serving time, **KV cache capacity determines maximum concurrency**, not model
size alone. A 13B model at FP16 occupies ~26GB of weights; a single request with a 4K context
window adds ~800MB of KV cache per layer (for a 40-layer model) — meaning a 16GB T4 can serve
the model but will OOM under concurrent long-context requests without careful KV cache limits.

vLLM's **PagedAttention** manages KV cache in non-contiguous pages (analogous to OS virtual
memory), eliminating fragmentation and enabling higher effective concurrency on constrained VRAM.
The `--max-model-len` and `--gpu-memory-utilization` knobs in vLLM manifests reflect this
directly — they are not tunables, they are the concurrency contract.

### Parallelism strategy by topology

| Strategy | What it splits | When to use | Bandwidth requirement |
|---|---|---|---|
| **Tensor parallel (TP)** | Weight matrices across GPUs; each step requires an all-reduce | Within a node with fast interconnect (NVLink / PCIe ×16) | High — all-reduce on every attention/FFN layer |
| **Pipeline parallel (PP)** | Layers across nodes; only activations cross the boundary | Across nodes over Ethernet; accepts bubble overhead | Low — only forward activations pass between stages |
| **Data parallel (DP)** | Independent requests across replicas | Throughput scaling of a model that fits on one GPU | Minimal |

On g4dn/g6 EKS nodes: use TP within a multi-GPU instance (PCIe), PP across nodes only when
the model cannot fit within a single node's aggregate VRAM. On H100 SXM: TP across all 8 GPUs
via NVLink — the 3.35 TB/s bisection bandwidth makes the all-reduce cost negligible.

### Quantization path

| Precision | HW requirement | Size reduction | Quality impact |
|---|---|---|---|
| FP16 / BF16 | any GPU | baseline | baseline |
| INT8 (W8A8) | any GPU; software path | ~2× | minor on large models |
| INT4 (AWQ / GPTQ) | any GPU | ~4× | measurable; acceptable for most tasks |
| **FP8 (W8A8)** | **Ada (L4/4090) or Hopper (H100) only** | ~2× vs FP16 | near-lossless on Hopper |

T4 does not have hardware FP8 support — FP8 serving on T4 falls back to software emulation and
loses most throughput benefit. This is the concrete reason L4 (g6) is the upgrade target: FP8
serving on L4 is hardware-accelerated, making the latency and throughput curves qualitatively
different, not just quantitatively better.

### Speculative decoding

For latency-sensitive paths: a small draft model (e.g. 1–3B) proposes K tokens ahead; the
target model verifies them in a single forward pass (parallel, cheap). On accepted sequences
this delivers K× latency improvement with identical output distribution. Implemented in vLLM
via `--speculative-model`. Load-bearing for the chat UI's time-to-first-token story.

### What DCGM measures that matters

The GPU Operator's DCGM exporter surfaces raw counters. The ones that drive operational
decisions:

| Metric | What it tells you |
|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | SM utilization — low during decode is expected, not a sign of underload |
| `DCGM_FI_DEV_MEM_COPY_UTIL` | Memory bandwidth utilization — the real decode bottleneck indicator |
| `DCGM_FI_DEV_FB_USED` | VRAM consumed — KV cache pressure visible here |
| `DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL` | NVLink utilization — TP all-reduce cost visible here |
| `DCGM_FI_DEV_POWER_USAGE` | Power draw — burst detection and cost attribution |

These map directly to Grafana dashboards and eventually to the Karpenter/KEDA scaling signals.

---

## 6. IaC maturity path (TF → GitOps → CRD-driven)

There is a bootstrap paradox: CRDs need a cluster to apply them, so something imperative
always lights the first match. The platform matures along that reality:

- **A — Terraform bootstrap.** TF provisions the cluster shell + GPU pool. `terraform destroy` is clean.
- **B — GitOps for apps.** ArgoCD app-of-apps owns everything inside the cluster; TF shrinks to the shell.
- **C — CRD-driven infra (Crossplane).** A small management cluster runs Crossplane + ArgoCD;
  GPU clusters themselves become git-synced CRDs. "Create an H100 cluster" becomes a git commit.

Autoscaling is two independent layers: **Karpenter / Cluster Autoscaler** (nodes scale to
zero when idle — the cost guarantee) and **KEDA / HPA** (vLLM replicas on request load).

## 7. AI-driven operation

- **Phase 0+ — Reviewer.** [Sentinel](../sentinel) runs on every PR via GitHub Actions,
  reading `CLAUDE.md` to enforce infra conventions (e.g. a vLLM parallelism change must come
  with the matching GPU node-pool change). Only PRs it gates merge → ArgoCD syncs.
- **Phase 4+ — Operator.** An agent watches the running platform for drift, orphaned cloud
  resources, and cost anomalies, and opens remediation PRs. The first autonomy slice is
  **orphan / cost-drift detection** — the same mechanism that protects the budget proves the
  self-management story.

## 8. Roadmap

The platform is built as an independently demoable ladder — each phase spins up, is tested,
demonstrated, and torn down clean. See [`docs/phases.md`](docs/phases.md) for the full ladder
and [`docs/decisions.md`](docs/decisions.md) for the locked design decisions.

| Phase | Outcome |
|---|---|
| 0 | Scaffolding: repo, `make up`/`down`, state backend, sentinel PR-gate, teardown-verifies-zero-orphans |
| 1 | Single-GPU inference on EKS + g4dn (T4); full GPU Operator + vLLM + DCGM observability stack |
| 2 | Distributed inference (KubeRay, TP within-node / PP across nodes, 32–72B models) |
| 3 | GitOps + ChatGPT-style UI + agentic layer; g6/L4 node-group swap when quota clears |
| 4 | Autoscaling (Karpenter + KEDA) + cost-autonomy operator |
| 5 | Multi-cloud H100/H200 burst — portability thesis proven live |
| 6 | CRD-driven infra (Crossplane) + fleet-wide self-management |
