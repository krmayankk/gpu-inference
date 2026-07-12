---
max_turns: 5
---
Keep the zero-residual-cost guarantee provable (ADR-0001/0006/0007). The
orphan sweep can only reclaim what it can see, and a pool can only prove
teardown if it ships the proof script.

1. **Every new cloud resource must be sweepable.** Any resource added under
   `infra/` must carry `Project=gpu-inference` and `Ephemeral=true` tags —
   either via the provider's `default_tags` (check the pool's provider block
   before flagging) or explicit tags on the resource. An untagged resource is
   invisible to `orphans.sh` and becomes silent spend after `make down`.
   Severity: high. Resources that cannot be tagged at all deserve a finding
   too: how will the sweep find them?

2. **A pool without `orphans.sh` cannot prove teardown.** A new directory
   under `infra/pools/<pool>/` must provide `up.sh`, `down.sh`, and
   `orphans.sh`. Missing any of the three: critical — block it.

3. **Nothing always-on.** No resource may survive `make down` except git,
   object storage (weights cache, dumps), and the bootstrap Terraform state
   backend. Flag NAT gateways, load balancers, always-on instances, schedules
   that re-create capacity, or anything whose lifecycle is not tied to
   `up.sh`/`down.sh`. Severity: critical.

4. **TTL dead-man's switch stays armed.** Changes to GPU node groups /
   `up.sh` must not remove or bypass the TTL kill-switch that zeroes the GPU
   ASG after `ttl_hours`. Severity: high.
