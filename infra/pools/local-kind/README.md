# pool: local-kind

The $0 Phase-0 substrate (ADR-0009). A local `kind` cluster, CPU-only, no cloud, no GPU. It exists
to run the **invariant** platform layer — the `inference` Service, the OpenAI `/v1` contract, the
chat UI, and the full `up`/`demo`/`down` lifecycle — before a cent is spent.

Hooks (called by `scripts/*` via `pool_hook`):
- `up.sh` — create the kind cluster, emit `.kubeconfig`
- `down.sh` — delete the cluster + kubeconfig
- `orphans.sh` — prove no cluster / no kind containers / no kubeconfig remain
- `preflight.sh` — docker daemon up, kind available (auto-downloaded into `./bin`)

The serving pod here is the CPU **mock** (`platform/serving/overlays/mock/`). Swapping to a GPU is
just a different pool (`POOL=aws`); `platform/` does not change.
