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
`infra/pools/<provider>/` and `values/<gpu>.yaml`.

**Why.** This is the mechanism — not the hope — behind "scales to H100 blindly." The NVIDIA
device plugin exposes `nvidia.com/gpu` identically on T4/4090/A100/H100, so workload manifests
never learn what hardware they run on. Only `tensor-parallel-size`, model id, and node count change.

**Consequence.** Anything GPU- or provider-specific that leaks above the seam is a design bug.

---

## ADR-0003 — Start on RunPod; AWS/GKE are later pool modules

**Decision.** Phase 1–4 dev runs on **RunPod**. AWS (EKS) and GKE are added later as pool
modules if/when a managed control plane is preferred.

**Why.** AWS GPU quota is gated (only a single instance type visible today; G/P quota
increases take days). RunPod gives modern GPUs by the hour with zero egress on weights and no
quota wait. Because of ADR-0002, this is not a one-way door — and being unblocked on RunPod
while AWS is gated *demonstrates* the portability thesis rather than contradicting it.

**Open validation (Phase 1 spike).** Confirm RunPod's K8s path: native Instant Cluster
Kubernetes vs. self-managed **k3s** on RunPod instances. Either satisfies ADR-0002 (both yield
a kubeconfig with `nvidia.com/gpu` nodes). Default to whichever is cleaner at build time;
self-managed k3s is the maximally-portable fallback.

---

## ADR-0004 — Dev GPU is modern (FP8-capable), not T4

**Decision.** Dev starts on a modern GPU — **RTX 4090 (24GB, Ada, FP8, ~$0.34–0.69/hr)** for
single-GPU work, **A100 80GB / L40S** for distributed work. Not T4.

**Why.** T4 (Turing, 16GB, no FP8) cannot demonstrate modern inference techniques (FP8 quant,
FA3-class kernels) — the techniques this platform targets. The cost delta over T4 is small;
the capability delta is large.

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
