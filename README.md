# gpu-inference

An ephemeral, self-managing Kubernetes platform for serving open-weight LLMs across
heterogeneous GPU providers — **stood up, demonstrated, and torn down to zero residual cost on
demand.** The design invariant: *the same stack runs identically on a $0.34/hr consumer GPU and
an 8×H100 cluster; only the node pool and parallelism parameters change.*

Full architecture in [`PLAN.md`](PLAN.md); locked decisions in [`docs/decisions.md`](docs/decisions.md);
the phase ladder in [`docs/phases.md`](docs/phases.md).

## Quickstart — a working chat demo in one command, $0

```bash
make demo            # kind cluster + OpenAI-compatible endpoint + chat UI, then a live round-trip
make chat            # open http://localhost:8080
make down            # destroy everything and PROVE zero orphans
```

`make demo` runs entirely on a local `kind` cluster with a CPU pod that speaks the OpenAI API — no
cloud account, no GPU, no cost. It is not a toy: it exercises the **exact** manifests that serve
real models on a GPU.

## The one idea

Everything above a stable `inference` Service (the OpenAI `/v1` contract, the chat UI, the whole
`make up`/`demo`/`down` lifecycle) is **invariant**. The only thing that changes between a laptop
and an 8×H100 cluster is the pool:

```bash
make demo                              # local kind + CPU mock          — $0
make up   POOL=aws GPU=l4 CONFIRM_SPEND=1       # EKS + L4 + vLLM      — ~$1.2/hr
make down POOL=aws                      # tear the expensive thing down
```

The identical `platform/` manifests serve the CPU mock and vLLM-on-GPU. That is the portability
thesis proven, not asserted (ADR-0002 / ADR-0009).

## Layout

```
Makefile                 single control surface (dispatch only)
scripts/                 up · down · demo · verify-zero-orphans · chat · lint
infra/
  bootstrap/             Terraform remote-state backend (the one persistent thing)
  pools/                 THE SEAM — provider/hardware-specific; nothing else is
    local-kind/          $0 CPU substrate (Phase 0)
    aws/                 EKS: system + GPU node groups; t4/l4 are profile rows (Phase 1)
platform/                THE INVARIANT — identical on every pool
  serving/base/          the `inference` Deployment + Service
  serving/overlays/mock  CPU pod speaking /v1 (Phase 0)
  serving/overlays/vllm  vLLM on GPU (Phase 1+)
  chat/                  streaming chat UI (nginx proxies /v1 -> inference)
  serving/gpus/<gpu>/    per-GPU serving contract: model, quantization, TP size
CLAUDE.md · sentinel.yml the AI PR gate's conventions + config
```

## Cost posture

- **Nothing is hand-built; nothing is left running.** `make down` removes 100% and
  `verify-zero-orphans` fails the teardown if anything survives (ADR-0006).
- Cloud pools tag every resource `Project=gpu-inference,Ephemeral=true`; teardown sweeps by tag
  plus explicit checks for leak-prone types (EBS, EIP, NAT, LB).
- Paid infra requires an explicit `CONFIRM_SPEND=1`. The only sanctioned persistent resource is
  the Terraform state backend (pennies/month).

## Status

Phase 0 (scaffolding + $0 chat demo) is **built and verified** — `make demo TEARDOWN=1` runs the
full lifecycle including the machine-checked seam contract (`scripts/contract.py`). Phase 1
(EKS + **L4/FP8** + vLLM + DCGM observability) is **in progress**: code complete, first paid
apply pending. See [`docs/phases.md`](docs/phases.md).

## Requirements

- **Phase 0:** Docker + `kubectl` + `python3`. `kind` is auto-downloaded into `./bin` if absent.
- **Phase 1:** `terraform`, `aws` (an identity that can create infra — preflight probes this),
  `helm`, `jq`, and the cleared G/VT quota (ADR-0003; approved us-east-1, 2026-07; us-west-2 pending).
