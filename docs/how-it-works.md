# How this platform works, end to end

*A reading companion. Written for someone who knows Kubernetes deeply but is new to GPUs,
Hugging Face, and model weights. Every section ends with the files to read. Keep it open
while you walk the code.*

---

## 1. The one-sentence architecture

A chat website talks to an OpenAI-compatible API behind a Kubernetes Service named
`inference` — and **nothing above that Service ever knows what's behind it**: a $0 CPU fake
on your laptop, or a real LLM on a GPU in AWS, or (later) a 70B model sharded across 8×H100.

That boundary is called **the seam** in this repo. Everything is organized around it:

```
platform/   the app        — identical bytes on every substrate (the INVARIANT)
infra/      the machines   — the ONLY place that knows about providers/hardware (the SEAM)
scripts/    the buttons    — make up / make demo / make down
```

> Read: `README.md` (the map), `docs/decisions.md` ADR-0002 and ADR-0009 (why the seam).

---

## 2. What actually serves the model: vLLM (we didn't write an inference engine)

**vLLM** is the industry-standard open-source LLM server. You hand it a model name and it
gives you an HTTP server speaking the same API as OpenAI's (`/v1/chat/completions`). It owns
all the hard GPU things — batching many users' requests together ("continuous batching"),
managing GPU memory for attention ("PagedAttention"), streaming tokens.

Our entire "integration" with it is ~6 command-line flags in one file:

```
--model=Qwen/Qwen2.5-Coder-7B-Instruct    which model to fetch and load
--served-model-name=gpu-inference         the public name clients see (stable everywhere)
--quantization=fp8                        smaller numbers -> fits in 24GB (see §5)
--max-model-len=8192                      max context length (a memory budget, see §5)
```

The pod definition (image, probes, scheduling) is *structure*; the flags are *hardware
knobs*. They live in different places on purpose — one structure, many hardware profiles:

> Read: `platform/serving/overlays/vllm/patch.yaml` (structure),
> `platform/serving/gpus/l4/args.yaml` (knobs for the L4 GPU; siblings: `t4/`, `h100/`).

The Phase-0 **mock** is the other occupant of the same seam: ~120 lines of stdlib Python
that speaks the same API with canned answers. It exists so the entire platform — UI,
Service, lifecycle, CI — runs and is tested at $0 without a GPU.

> Read: `platform/serving/overlays/mock/server.py`, and note both overlays patch the SAME
> base Deployment: `platform/serving/base/deployment.yaml`.

---

## 3. Hugging Face: the Docker Hub of models

**Hugging Face Hub** is a registry of model repositories, the way Docker Hub is a registry
of images. A "model" is a repo (`Qwen/Qwen2.5-Coder-7B-Instruct`) containing:

- `config.json` — the architecture description
- tokenizer files — how text becomes numbers
- `*.safetensors` — **the weights**: the billions of learned numbers, sharded into a few
  multi-GB files. (`safetensors` is a deliberately dumb, safe format — the older PyTorch
  format could execute code on load. The ecosystem migrated for that reason.)

vLLM has the Hub client built in: give it `--model Qwen/...` and it downloads the repo
(resumable, checksummed) into a local cache directory, then memory-maps the weights onto
the GPU. Anyone can serve almost any open model this way; the only wall is VRAM (see §5).
Some models (Llama) are license-gated and need a token; Qwen is public — that's why you
see no secret handling in the manifests.

---

## 4. The weights problem, and our S3 pull-through cache

Weights are big (~15GB for our 7B model; 100s of GB for large ones). Re-downloading them
from Hugging Face on every pod start wastes minutes and money — and this platform's whole
philosophy is "clusters are disposable" (ADR-0001), so pods start from nothing often.

Our design — three small pieces, no magic:

```
boot #1:  initContainer tries S3 cache -> MISS -> vLLM downloads from HF (~8 min)
          you run `make cache-weights`  -> pushes the cache up to S3
boot #2+: initContainer tries S3 cache -> HIT  -> weights land in ~1 min, FREE
```

Why free: the VPC has an **S3 gateway endpoint**, so traffic to S3 bypasses the NAT gateway
(NAT egress costs $0.045/GB; the gateway endpoint costs nothing). The weights bucket is one
of exactly two resources that survive teardown (tagged `Ephemeral=false`), with a 60-day
expiry — weights are re-fetchable by definition, so we don't hoard.

> Read: the `initContainers` + `cache-sync` sidecar in
> `platform/serving/overlays/vllm/patch.yaml`; `scripts/cache-weights.sh`;
> the weights bucket in `infra/bootstrap/main.tf`; the gateway endpoint in
> `infra/pools/aws/main.tf` (`aws_vpc_endpoint.s3`).

---

## 5. Why "quantization" and "max-model-len" are memory math, not tuning

Two facts drive every GPU decision:

1. **Weights must fit in GPU memory (VRAM).** A 7-billion-parameter model at 16-bit
   precision = ~14GB. Quantization stores the numbers smaller: **FP8** (8-bit) halves it to
   ~7GB with almost no quality loss — *if the GPU has FP8 circuits*. Our L4 (Ada
   architecture) does; the older T4 doesn't (it would silently emulate, slowly). That
   hardware fact is the entire reason the platform's default GPU is L4 and why the t4
   profile pins AWQ instead — see the comments in `platform/serving/gpus/*/args.yaml`.

2. **Serving needs VRAM beyond the weights: the KV cache.** For every active request, the
   GPU stores attention state proportional to context length × concurrent users. On a 24GB
   L4: ~8GB weights + KV cache in the rest. `--max-model-len 8192` is a *budget*: longer
   context = fewer concurrent users before memory runs out. It's a contract, not a tunable.

Bonus fact that explains benchmarks later: generating tokens is limited by **memory
bandwidth**, not compute — the GPU re-reads all the weights for every token. That's why an
H100 (3.35 TB/s) beats an L4 (0.86 TB/s) on generation speed by ~4×, roughly its bandwidth
ratio. Watch `DCGM_FI_DEV_MEM_COPY_UTIL` in Grafana, not `GPU_UTIL`, to see the real
bottleneck. (Longer version: `PLAN.md` §5.)

---

## 6. How Kubernetes gives a pod a GPU

You know the scheduler; here's the GPU-specific chain:

```
AMI (AL2023_x86_64_NVIDIA)      NVIDIA driver + container runtime baked into the node image
        │
GPU Operator (Helm)             we install it with driver DISABLED — the AMI owns the driver.
        │                       It contributes three things:
        ├── device plugin       advertises `nvidia.com/gpu: 1` as a schedulable resource
        ├── GFD                 labels nodes with GPU properties (nvidia.com/gpu.present=true)
        └── DCGM exporter       GPU metrics -> Prometheus -> Grafana
        │
our pod                         requests `nvidia.com/gpu: 1` + tolerates the GPU taint
```

The GPU node group is **tainted** so only the model server lands on it; everything else
(chat, CoreDNS, Prometheus, the operator's own controllers) lives on a small untainted
`system` node group. This two-pool layout is why the cluster works at all — a cluster with
only tainted nodes can't even run DNS.

The pod's manifests never name a GPU model. `nvidia.com/gpu: 1` means the same thing on a
T4, L4, or H100 — that's the mechanism behind "the same manifests run everywhere."

> Read: `scripts/up.sh` (operator install, step 3), `infra/pools/aws/main.tf` (node groups,
> taint, AMI), tolerations in `platform/serving/overlays/vllm/patch.yaml`.
> Decision record: ADR-0010 (managed node groups now, Karpenter in Phase 4, DRA in Phase 2).

---

## 7. The lifecycle: up, demo, down — and the paranoia built into each

- **`make up`** — pool provisions the substrate (kind locally; Terraform+EKS on AWS), then
  the invariant layer applies identically. Paid pools require `CONFIRM_SPEND=1`, and
  preflight *probes* that your AWS identity can actually create things before Terraform
  burns 20 minutes discovering it can't.
- **`make demo`** — up, then the **contract test**: 11 machine-checked assertions against
  the live API (model listing, completion shape, multi-turn, streaming). The same
  assertions must pass against the mock and against vLLM — *that is the seam, proven*.
  CI runs the whole thing on every PR.
- **`make down`** — destroy, then the **orphan sweep**: queries AWS for anything still
  tagged `Project=gpu-inference, Ephemeral=true`, plus explicit checks for the classic
  leakers (EBS volumes, Elastic IPs, NATs, load balancers). A dirty sweep FAILS the
  teardown; so does an API error — a sweep that can't see never gets to say "clean". It
  also knows the difference between live resources and AWS-managed death states (a KMS key
  in its mandatory 30-day deletion window is not a leak).

Two safety nets you should know exist even if you never see them fire:

- **TTL dead-man's switch**: every `make up` schedules the GPU nodes to scale to zero 6
  hours later. A forgotten cluster stops burning GPU money by itself.
- **MFA-gated credentials**: the AWS account denies everything without MFA; work happens
  through a short-lived session token. Stolen keys are inert. (`infra/pools/aws/README.md`
  documents the exact procedure.)

> Read: `scripts/demo.sh`, `scripts/contract.py`, `infra/pools/aws/orphans.sh`,
> the TTL block at the end of `infra/pools/aws/up.sh`.

---

## 8. Money, plainly

| State | $/hr |
|---|---|
| Local (kind + mock) | 0 |
| AWS up, L4 serving | ~1.2 (GPU 0.98 + EKS 0.10 + NAT 0.05 + system nodes 0.08) |
| AWS after `make down` | 0 (plus ~pennies/mo: state bucket + weights cache) |
| 8×H100 burst, rented hourly off-AWS (Phase 5) | ~24 — a full demo ≈ $75, no commitment |

Quota trivia that bit us once: AWS GPU quotas are denominated in **vCPUs per instance
family** (one dial per family, all sizes). Our 32 approved vCPUs in us-east-1 = up to four
g6.2xlarge (4 GPUs) — and quotas are **per region**, which is why the first apply failed in
us-west-2 (quota 0 there; the sweep-verified teardown and region move took ~30 minutes,
which is the ephemerality thesis earning its keep).

---

## 9. What's real today vs. what's coming

| Piece | Status |
|---|---|
| Chat UI, OpenAI API, contract test, CI, teardown proof | real, verified locally at $0 |
| EKS + L4 + vLLM + Qwen-7B FP8 + DCGM/Grafana | Phase 1 — being applied now |
| Multi-GPU (tensor parallel), KubeRay, DRA | Phase 2 |
| GitOps (ArgoCD), persistence, IRSA hardening | Phase 3 |
| Karpenter + KEDA autoscaling, cost-autonomy agent | Phase 4 |
| 8×H100 burst on a rented cluster, same manifests | Phase 5 |

The phase ladder with per-phase demo/teardown criteria: `docs/phases.md`.
Every "why" that was decided rather than defaulted: `docs/decisions.md` (10 ADRs).
