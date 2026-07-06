# CLAUDE.md — conventions the Sentinel PR gate enforces

Sentinel (`.github/workflows/sentinel.yml`) reads this file and blocks PRs that
violate these invariants. They are the load-bearing rules of the architecture,
not style preferences. Rationale lives in `docs/decisions.md` (the ADRs).

## The portability seam is sacred (ADR-0002)
- The ONLY provider/hardware-specific code lives in `infra/pools/<pool>/` and
  `platform/serving/gpus/<profile>/`. Anything provider- or GPU-specific that
  appears in `platform/serving/base|overlays`, `platform/chat`, `scripts/`, or
  the Makefile is a design bug — flag it.
- `platform/` manifests must reach the mock and every GPU pool unchanged. A
  change to `platform/serving/base/` or `platform/chat/` that assumes a specific
  backend breaks the seam.
- Pool = provider; hardware = profile. A new GPU is a row in the pool's
  `gpu_profiles` map plus a `platform/serving/gpus/<profile>/` — flag a PR that
  adds hardware as a new pool instead.

## Parallelism changes travel with their hardware (ADR-0002/0004)
- A change to `--tensor-parallel-size` MUST come with the matching GPU capacity:
  a `gpu_profiles` row / node count able to hold that parallelism, and a
  matching `nvidia.com/gpu` resource limit in the same profile. TP without the
  GPUs to back it is an incomplete change.
- Quantization must match the hardware: `fp8` only on Ada/Hopper profiles
  (`gpus/l4/`, `gpus/h100/`) — never in `gpus/t4/` (Turing has no hardware FP8;
  it silently degrades to emulation). Flag fp8 landing in the t4 profile.
- Every GPU profile must pin `--served-model-name=gpu-inference` — clients
  (chat UI, contract test) depend on that public id on every pool.

## The cost guarantee must stay provable (ADR-0006)
- Every new cloud resource MUST carry `Project=gpu-inference` and
  `Ephemeral=true` tags (via provider `default_tags` or explicit tags). Untagged
  resources are invisible to the orphan sweep — flag them.
- A new pool under `infra/pools/<pool>/` MUST provide `up.sh`, `down.sh`, and
  `orphans.sh`. A pool without `orphans.sh` cannot prove teardown — block it.
- No always-on paid resources (ADR-0001/0007). Anything that survives
  `make down` other than git + object storage is a leak. The bootstrap state
  backend is the single sanctioned exception.

## GitOps is the mutation path
- Provisioning belongs in Terraform (`infra/`); in-cluster components belong in
  `platform/` (kustomize/Helm), not baked into Terraform (ADR-0008).
