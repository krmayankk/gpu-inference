---
max_turns: 5
---
Enforce the per-GPU serving contract (ADR-0002/0004): parallelism and
quantization changes must travel with the hardware that backs them.

1. **Tensor parallelism needs GPUs to back it.** If the diff changes
   `--tensor-parallel-size` in any `platform/serving/gpus/<profile>/`, the same
   PR must provide matching capacity: a `gpu_profiles` row in
   `infra/pools/*/` whose GPU count / node sizing can hold that parallelism,
   AND an `nvidia.com/gpu` resource limit in the same profile directory equal
   to the per-pod GPU count. Read the profile's manifests and the pool's
   `gpu_profiles` map to verify the numbers actually line up — e.g. TP=4 with
   `nvidia.com/gpu: 1` or with an instance type that carries a single GPU is
   an incomplete change. Severity: high.

2. **Quantization must match the silicon.** `fp8` is only valid in Ada/Hopper
   profiles (`platform/serving/gpus/l4/`, `gpus/h100/`). Flag `fp8` (as
   `--quantization fp8`, `--kv-cache-dtype fp8`, or a model id implying FP8
   weights) landing in `gpus/t4/` — Turing has no hardware FP8 and silently
   degrades to emulation. Severity: high.

3. **The public model id is pinned.** `scripts/lint.sh` already fails when a
   profile lacks the literal `--served-model-name=gpu-inference` — don't
   re-report bare absence. Your judgment layer: flag it being pinned but
   *ineffective* — set on the wrong container, overridden by a later arg or
   env var, or a client that stops using the public id. Every GPU profile
   (and the mock) must actually serve `gpu-inference`. Clients — the chat UI and
   `scripts/contract.py` — depend on that id on every pool. Flag a profile
   that drops or renames it, or a new profile that forgets it. Severity:
   critical (it breaks every client on that pool).
