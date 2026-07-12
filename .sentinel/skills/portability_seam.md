---
max_turns: 5
---
Guard the portability seam (ADR-0002/0009): the ONLY provider- or
hardware-specific code in this repo lives in `infra/pools/<pool>/` and
`platform/serving/gpus/<profile>/`. Everything else must be able to reach the
CPU mock and every GPU pool byte-identical.

Check the diff for seam leakage:

1. Provider or hardware specifics appearing in `platform/serving/base/`,
   `platform/serving/overlays/`, `platform/chat/`, `scripts/`, or the
   `Makefile`: instance types (g4dn, g6, p5...), AMI ids, GPU model names
   (T4, L4, A100, H100), provider names or APIs (aws, eks, runpod), cloud-only
   annotations, nodeSelectors/tolerations naming specific hardware. Grep the
   touched files above the seam for these markers. Severity: high; critical if
   the change means `platform/serving/base/` or `platform/chat/` manifests can
   no longer apply unchanged against both the mock overlay and a GPU pool.

2. Hardware added as a pool instead of a profile. Pool = provider; hardware =
   profile. A new GPU must be a row in an existing pool's `gpu_profiles` map
   plus a new `platform/serving/gpus/<profile>/` directory. Flag a new
   directory under `infra/pools/` whose distinguishing feature is a GPU model
   of a provider that already has a pool (e.g. `infra/pools/aws-h100/`).
   Severity: high.

3. The mock overlay being repurposed as a real backend or losing its
   self-identification as a mock (ADR-0009 requires it to stay honest).
   Severity: medium.

Do not flag hardware specifics inside `infra/pools/<pool>/` or
`platform/serving/gpus/<profile>/` — that is exactly where they belong.
