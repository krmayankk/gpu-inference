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
Request via AWS Service Quotas console or:
```
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-DB2E81BA \
  --desired-value 32 --region us-east-1
```
Small increases typically resolve in minutes to hours. File now; build on g4dn meanwhile.
Also confirm g6 availability in the target region:
```
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters Name=instance-type,Values=g6.2xlarge \
  --region us-east-1 --output table
```

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
