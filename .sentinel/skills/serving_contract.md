---
max_turns: 5
---
Enforce the per-GPU serving contract (ADR-0002/0004): parallelism and
quantization changes must travel with the hardware that backs them.

1. **Parallelism needs GPUs to back it — the arithmetic must close.** If the
   diff changes `--tensor-parallel-size` or `--pipeline-parallel-size` in any
   `platform/serving/gpus/<profile>/`, verify the capacity equation:
   TP × PP must equal the total GPUs the profile's pods request
   (sum of `nvidia.com/gpu` limits across all pods — for a RayCluster that is
   head + `workerGroupSpecs.replicas`), AND the pool's `gpu_profiles` row must
   provide that many GPUs (`node_count` × GPUs per instance). Read the
   profile's manifests and the pool map and do the multiplication — e.g. PP=4
   with 3 worker replicas + 1 head × 1 GPU each backed by `node_count = 4`
   closes; PP=4 with `node_count = 1`, or TP=4 with `nvidia.com/gpu: "1"` on
   a single pod, is an incomplete change. Severity: high.

1b. **Parallelism kind must match the interconnect (ADR-0011).** TP all-reduces
   every layer and belongs within one box (NVLink/PCIe — a multi-GPU instance
   type); PP tolerates ordinary networks and is the multi-*node* pattern. Flag
   `--tensor-parallel-size > 1` spread across single-GPU nodes (it will crawl
   over ENA), and flag a multi-node profile whose kustomization lacks the
   `inference` Service fronting the serving pod — Ray-based profiles bring
   their own workload but the Service name/port contract is unchanged.
   Severity: high.

2. **Quantization must match the silicon.** `fp8` is only valid in Ada/Hopper
   profiles (`platform/serving/gpus/l4/`, `gpus/h100/`). Flag `fp8` (as
   `--quantization fp8`, `--kv-cache-dtype fp8`, or a model id implying FP8
   weights) landing in `gpus/t4/` — Turing has no hardware FP8 and silently
   degrades to emulation. Severity: high.

3. **The public model id is pinned.** Every GPU profile (and the mock) must
   serve `--served-model-name=gpu-inference`. Clients — the chat UI and
   `scripts/contract.py` — depend on that id on every pool. Flag a profile
   that drops or renames it, or a new profile that forgets it. Severity:
   critical (it breaks every client on that pool).
