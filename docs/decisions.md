# Design Decisions (ADR)

Locked architectural decisions. Each is a one-way enough door to be worth recording, and
each is justified against the platform's four goals: **infra depth · modern inference ·
blind H100 portability · zero-residual-cost ephemerality.**

---

## ADR-0001 — Everything is ephemeral; nothing is hand-built

**Decision.** The entire platform is created from git on `make up` and removed on `make down`.
No click-ops, no long-lived clusters. The only persistent state is git + object storage
(weights cache, Postgres dumps).

**Why.** Under full ephemerality, control-plane cost arguments dissolve (a managed control
plane for a 4-hour demo costs cents). Reproducibility — every spin-up is byte-identical —
is the foundation of cost safety and operational confidence.

**Consequence.** No always-on public demo; demos are spin-up events. Acceptable for
demo-grade. Product-grade always-on is a later, explicit decision (see ADR-0007).

---

## ADR-0002 — Kubernetes + GPU Operator are the invariant; the GPU pool is the only seam

**Decision.** Everything above the node level (GPU Operator, KubeRay, vLLM, ArgoCD,
observability, UI) is identical across all hardware. Provider/hardware specifics live only in
`infra/pools/<provider>/` and `platform/serving/gpus/<profile>/` (the per-hardware serving
contract: model, quantization, parallelism — a manifest that is applied, not transcribed).

**Why.** This is the mechanism — not the hope — behind "scales to H100 blindly." The NVIDIA
device plugin exposes `nvidia.com/gpu` identically on T4/4090/A100/H100, so workload manifests
never learn what hardware they run on. Only `tensor-parallel-size`, model id, and node count change.

**Consequence.** Anything GPU- or provider-specific that leaks above the seam is a design bug.

---

## ADR-0003 — EKS is the primary K8s substrate; g4dn now, g6 when quota clears

**Decision.** Phase 1–5 dev runs on **AWS EKS**. Phase 1 starts on **g4dn** (T4, available
today); **g6** (L4, Ada, FP8) is the target node group once a quota increase clears. GKE and
H100 burst providers (Lambda, CoreWeave) are later pool modules. RunPod is disqualified as a
primary — its Instant Clusters are Slurm-based and explicitly incompatible with Kubernetes.

**Why.** The platform's hard requirement is K8s-native end-to-end (GPU Operator, KubeRay,
ArgoCD, Karpenter — all require real K8s). EKS is the managed K8s with the deepest NVIDIA GPU
Operator support documentation and the most enterprise deployment precedent. Starting on
available g4dn hardware means the entire stack is working before the g6 quota arrives — the
node-group swap is then a single Terraform change, validating ADR-0002 in practice.

**Quota path for g6.** Quota name: "Running On-Demand G and VT instances" (code `L-DB2E81BA`).
Requested and **approved 2026-07 in us-east-1** (32 vCPUs, verified via the service-quotas API — the ADR’s original request command targeted us-east-1). A us-west-2 request for 32 is PENDING (filed 2026-07-05); the platform region follows wherever quota is actually live.

**Amendment (2026-07): pool = provider, hardware = profile.** The pool was originally named
`aws-g4dn`; that baked hardware into the provider seam and would have made every GPU a new pool.
Corrected: the pool is `infra/pools/aws/`; T4/L4 are rows in its `gpu_profiles` map selected by
`GPU=t4|l4`, paired with `platform/serving/gpus/<profile>/` above the seam. Scaling the hardware
ladder (t4 → l4 → h100-class) adds rows and profiles, never pools — one seam, two axes.

---

## ADR-0004 — Phase 1 on T4 (g4dn); L4 (g6) is the FP8 upgrade target

**Decision.** Phase 1 uses **g4dn.2xlarge (T4, 16GB)** — available today. **g6.2xlarge (L4,
24GB, Ada)** replaces it at Phase 1→2 transition once quota clears. Nothing above the node pool
changes.

**Why T4 is an acceptable Phase 1 substrate.** The K8s + GPU Operator + KubeRay + vLLM stack
is architecture-invariant — it runs identically on T4 and H100. Phase 1 validates the stack,
not the GPU. Known T4 limitations are concrete and documented:
- No hardware FP8 (Turing arch, pre-Ada). FP8 serving falls back to software emulation — high
  overhead, loses most throughput benefit. INT8 and INT4 (AWQ/GPTQ) are the practical
  quantization paths on T4.
- 16GB VRAM: fits 7B FP16 (~14GB) or 13B INT4 (~7GB). KV cache headroom is tight under
  concurrent long-context requests; `--gpu-memory-utilization 0.85` and
  `--max-model-len 4096` are the operating knobs.
- Memory bandwidth 300 GB/s (vs H100 SXM 3.35 TB/s): decode throughput is proportionally
  lower. Decode is memory-bandwidth-bound, not compute-bound.

**Why L4 (g6) is the target.** Ada Lovelace architecture adds hardware FP8 (W8A8) — same
precision as Hopper's transformer engine path. 24GB VRAM fits 13B FP16 comfortably with
room for KV cache. 864 GB/s memory bandwidth. The transition from g4dn to g6 is the concrete
moment the platform demonstrates the FP8 serving path and higher concurrency under load.

**Why not skip T4 and wait for g6.** Building on g4dn unblocks Phase 0–1 without waiting
on quota. The architectural discipline of running on constrained hardware first — understanding
the KV cache pressure, the decode bandwidth limits, the model size trade-offs — produces better
operational tuning for all subsequent hardware. It is not a compromise; it is the correct
order of operations.

**Amendment (2026-07): the quota cleared before Phase 1's first apply — L4 is the Phase-1 GPU.**
T4-first was a sequencing decision driven by quota latency, not a preference; its premise expired.
Phase 1 launches directly on g6/L4 (`GPU=l4` default): hardware FP8 from day one, 24GB of KV-cache
headroom, and ~3× the memory bandwidth for the decode path. The t4 profile remains in the map and
in `platform/serving/gpus/t4/` as the fallback if g6 capacity is ever unavailable — kept because
keeping it costs one file, and it documents the Turing/no-FP8 constraint that shaped PLAN §5.

---

## ADR-0005 — State lives outside the GPU lifecycle

**Decision.** Model weights cache on a network volume / S3 / R2; conversation history as
Postgres dumps in object storage. Clusters and everything in them are disposable.

**Why.** Re-downloading 100s of GB of weights on every spin-up is the single biggest avoidable
cost. Decoupling state from GPU lifecycle makes teardown safe and spin-up fast.

---

## ADR-0006 — Cost hygiene is enforced, then automated

**Decision.** Cost safety ships as concrete mechanisms, escalating to autonomy:
- 100% declarative → `terraform destroy` / `make down` removes everything.
- One-command lifecycle: `make up PROVIDER=runpod GPU=h100` / `make down`.
- TTL auto-termination: GPU pools self-expire after N idle hours.
- Scale-to-zero: Karpenter consolidates idle GPU nodes to zero.
- **Orphan / cost-drift detection** scans for leaked volumes/IPs/LBs and reports.

**Why.** Real GPU money demands this be load-bearing. The orphan-detection mechanism is the
first job handed to the operator agent (ADR shared with the autonomy roadmap): the thing that
protects the budget is the same thing that proves self-management.

---

## ADR-0007 — Demo-grade now; product-grade is a later explicit step

**Decision.** Build demo-grade (spin-up demos) with the architecture cleanly able to
graduate to product-grade (auth, persistence, multi-user, always-on small model). Do not pay
product cost before there is a reason.

**Why.** The ChatGPT-style UI is the user-facing surface over the platform (autonomous,
self-managing, multi-cloud GPU inference), not its core value. Real chat/agentic traffic, when
it exists, becomes an organic workload generator — but that is a graduation, not a Phase 1
requirement.

---

## ADR-0008 — IaC matures TF → GitOps → Crossplane (CRD-driven)

**Decision.** Phase A: Terraform bootstraps the cluster shell + GPU pool. Phase B: ArgoCD
app-of-apps owns everything in-cluster. Phase C: Crossplane on a small management cluster makes
the GPU clusters themselves git-synced CRDs.

**Why.** The bootstrap paradox forbids pure CRD-only from a cold start. The TF→Crossplane
progression is the genuine modern-infra maturity curve and, for a multi-cloud footprint,
Crossplane (provider CRDs across AWS+GCP+RunPod) fits better than Cluster API (best for
self-managed clusters on raw VMs).

---

## ADR-0009 — The seam extends to the serving pod; Phase 0 proves the whole invariant at $0

**Decision.** The portability seam (ADR-0002) is realized not only at the GPU node but at the
**serving pod**. Above a stable `inference` Service speaking the OpenAI `/v1` contract, nothing —
not the chat UI, not the lifecycle, not the manifests — knows what serves it. Phase 0's substrate
is a **local `kind` cluster** exposed as a first-class pool module (`infra/pools/local-kind/`,
`POOL=local-kind`) running a **CPU "mock" pod** that speaks `/v1/chat/completions`. Phase 1 swaps
*only that pod* for vLLM on EKS g4dn by changing `POOL`; `platform/` is byte-identical.

**Why.** Two forcing functions the plan already carries — "every phase is independently
demoable" (§8) and "cost hygiene is a feature" (§1) — are strongest when the very first phase
produces a **working chat demo at zero cost with clean teardown**. Making `kind` a real pool and
the mock a real OpenAI-compatible backend means Phase 0 exercises the entire invariant stack
(Service contract, UI, `make up`/`demo`/`down`, zero-orphan proof) before a cent is spent. The
cheap path becomes *evidence for* ADR-0002 rather than an exception to it: if the identical
`platform/` manifests serve both the CPU mock and vLLM-on-GPU, the seam is proven, not asserted.

**Consequence.** The serving layer carries a mock overlay (`platform/serving/overlays/mock/`)
alongside the vLLM overlay. The mock is demo/test infrastructure, never a fallback for real
inference — it must stay honest about being a mock (it says so in its own replies). `make demo`
is the per-phase showcase contract; `make down` is the per-phase teardown contract.

---

## ADR-0010 — Managed node groups until Karpenter; never hand-rolled ASGs

**Decision.** EKS capacity is EKS **managed node groups**: `system` (small, untainted — CoreDNS,
operators, chat, observability) and `gpu` (tainted `nvidia.com/gpu:NoSchedule`, `min_size=0`,
`AL2023_x86_64_NVIDIA`). Self-managed ASGs are rejected. **Karpenter (Phase 4) replaces the gpu
node group** with pod-driven NodePools; `system` remains an MNG hosting the Karpenter controller.

**Why.** MNG gives node join, drain-on-scale-down, taints/labels, and the NVIDIA AMI as
declarations; a self-managed ASG re-implements all of that as userdata and lifecycle hooks. The
only things self-managed buys (fine-grained provisioning, spot mixing, exotic launch templates)
are precisely what Karpenter does better — so the self-managed rung of the ladder would be built
only to be discarded. MNG still creates an ASG underneath, which is where the TTL dead-man's
switch attaches its scale-to-zero schedule (see `infra/pools/aws/up.sh`).

**Consequence.** Static `desired_size` capacity until Phase 4 — acceptable for single-node
inference demos; the KEDA/Karpenter pair owns elasticity later. Public API endpoint and node-role
S3 access are the matching demo-grade simplifications (IRSA + private endpoint are Phase-3
hardening, noted in docs/phases.md).

---

## ADR-0011 — Multi-GPU profiles bring their own workload; the seam stays at the Service

**Decision.** A GPU profile whose model cannot fit one GPU does not patch the single-pod
vLLM Deployment — its `platform/serving/gpus/<profile>/` ships a **KubeRay RayCluster**
(vLLM with the Ray distributed backend) plus the same `inference` Service every other
profile has. Phase 2's `l4x4` is the first: Qwen3-32B-FP8, **PP=4 across 4× g6.2xlarge**
(1 L4 each), head pod serving the OpenAI API.

**Why PP across nodes, not TP.** Tensor parallelism all-reduces at every layer — over
inter-node ENA networking that is the bottleneck; pipeline parallelism ships only stage-
boundary activations and tolerates ordinary networks. TP belongs inside a box (NVLink/PCIe):
TP=4 in one g6.12xlarge is the natural comparison, but at 48 vCPUs it exceeds the 32-vCPU
G-quota, while 4× g6.2xlarge = 32 exactly. Measure PP now; measure TP when quota clears.

**Why this doesn't break the seam.** ADR-0009 placed the seam at the `inference` Service,
not at the Deployment: "above a stable `inference` Service … nothing knows what serves it."
The profile directory is *below* the seam — exactly where hardware-shaped workloads belong
(ADR-0002). Chat UI and contract test reach l4x4 unchanged; capacity travels with the
profile via `gpu_profiles.<key>.node_count` so parallelism is never declared without GPUs.

**Consequence.** The KubeRay operator joins the invariant in-cluster layer on GPU pools
(idle cost ≈ one small pod). `up.sh`'s readiness gate handles both shapes: Deployment
rollout, or Ray head pod Ready (which implies vLLM /health passed and all stages placed).
