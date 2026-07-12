---
name: Review Claude GPU Inference Code
description: A skill to review code written by Claude for the gpu-inference project to ensure it adheres to the strict design principles and phases laid out in the architecture docs.
---

# Reviewing Claude's Work on gpu-inference

When asked to review code written by Claude for the `gpu-inference` repository,
follow these guidelines to ensure architectural integrity. The authoritative
invariants live in `CLAUDE.md` (enforced by the Sentinel PR gate) and
`docs/decisions.md` (the ADRs); this skill is the human-review companion.

## 1. Verify the load-bearing invariants (CLAUDE.md + decisions.md)
* **The portability seam (ADR-0002/0009):** provider/hardware specifics live
  ONLY in `infra/pools/<pool>/` and `platform/serving/gpus/<profile>/`.
  `platform/` manifests must reach the CPU mock and every GPU pool unchanged.
  Pool = provider, hardware = profile — new GPUs are `gpu_profiles` rows +
  a `gpus/<profile>/` dir, never new pools.
* **Parallelism travels with hardware (ADR-0004):** `--tensor-parallel-size`
  changes need matching GPU capacity and `nvidia.com/gpu` limits in the same
  PR; `fp8` only on Ada/Hopper profiles (l4/h100, never t4); every profile
  pins `--served-model-name=gpu-inference`.
* **Ephemerality stays provable (ADR-0001/0006):** every cloud resource tagged
  `Project=gpu-inference` + `Ephemeral=true`; every pool ships `up.sh`,
  `down.sh`, `orphans.sh`; nothing survives `make down` except git + object
  storage + the bootstrap state backend.
* **GitOps is the mutation path (ADR-0008):** provisioning in Terraform
  (`infra/`), in-cluster components in `platform/` (kustomize/Helm), not
  baked into Terraform.

## 2. Check the phase alignment
* Phases 0 (mock-on-kind seam) and 1 (vLLM on EKS/L4, FP8, closed 2026-07-05)
  are **built**. Current work targets Phase 2 (distributed inference: KubeRay,
  TP/PP, DRA) — see `docs/phases.md` and `docs/backlog.md` for the debts a
  Phase-2 PR is expected to pick up (e.g. contract backend-identity pinning
  is slated for Phase 2's first PR).
* Ensure changes match the phase's cost posture: money is spent only while a
  phase is up, and every phase must return the account to proven zero.

## 3. How to conduct the review
1. Read the relevant changes (latest git diffs or file updates).
2. Cross-reference against `CLAUDE.md`, `PLAN.md`, `docs/phases.md`,
   `docs/decisions.md`, and `docs/backlog.md`.
3. Note that Sentinel (`.github/workflows/sentinel.yml`) runs the same
   invariants on every PR, including the repo-specific judgment skills in
   `.sentinel/skills/` — your review should agree with or sharpen its
   findings, not duplicate mechanical checks it already covers.
4. Provide clear, direct feedback on any violation of the design goals,
   especially cost hygiene and ephemerality — do not let those slide.
