# 6-Data-Parallelism — Akamas resources

**Created:** 2026-09-07 (scaffolded from `5-pack-changes`, config aligned to
`2-larger-model-g7e`)

Measures **goodput** — `vLLM.prefill_token_throughput + vLLM.decode_token_throughput`
subject to a P95 TTFT ≤ 1500ms / P95 ITL ≤ 300ms SLA — for `Qwen/Qwen2.5-7B-Instruct`,
served by vLLM on a new node group (`llm-serving-l4`, g6.12xlarge, 4x NVIDIA L4 24GB).
Not a tuning study: 4 fixed-configuration steps (`baseline` + 3 `preset`) that vary
**only** `vLLM.data_parallel_size` (1/2/3/4), no optimize step, no
`parametersSelection`/`parameterConstraints` — goal/windowing/model/load pattern are
otherwise identical to `2-larger-model-g7e`. The full 98-metric telemetry catalog and
all 6 components from `5-pack-changes` (DCGM, PSI cluster/container, both scoped to
this study's own node group) are carried over unchanged in shape, just re-pointed to
`llm-serving-l4`.

## Versions

- **vLLM optimization pack**: **1.6.1** (bumped 2026-09-07 on
  `feature/mfu-compute-bandwidth-metrics`) — **TODO, re-verify**: `akamas describe
  optimization-pack vLLM`.
- **GPU optimization pack**: **1.1.0** (`feature/dcgm-counters-coverage`) — **TODO,
  re-verify**: `akamas describe optimization-pack GPU`.
- **Kubernetes optimization pack**: **1.8.0-dev** (`feature/psi-cluster-metrics`) —
  **TODO, re-verify**: `akamas describe optimization-pack "Kubernetes"`.
- **Target workload**: `Qwen/Qwen2.5-7B-Instruct`, image tag `vllm/vllm-openai:v0.22.0`
  — identical to `2-larger-model-g7e`. **Not yet proven on NVIDIA L4/Ada Lovelace** —
  this is the first study on this GPU generation in this repo, unlike every prior
  study's hardware which had prior art here to lean on. Smoke-test manually first.
- **Telemetry provider**: Prometheus (via `kube-prometheus-stack`).

## System

Same 6 components as `5-pack-changes`, re-pointed to this study's own node group:
- `vLLM` → `vLLM` (`prometheus.{pod,model}: .*`, unchanged).
- `gpu` → `GPU` (`prometheus.{pod,gpu}: .*`, unchanged).
- `container` → `Kubernetes Container`, `prometheus.pod: ^vllm-.*` (unchanged — pod
  name prefix doesn't depend on which node group it schedules on).
- `container_loadtest` → `Kubernetes Container`, `prometheus.pod:
  ^aiperf-benchmark-.*` (unchanged).
- `cluster` → `Kubernetes Cluster`, **`prometheus.node_role: llm-serving-l4`**
  (changed from `llm-serving` — this study's GPU node group).
- `cluster_loadtest` → `Kubernetes Cluster`, **`prometheus.node_role: system-m8a`**
  (changed from `system` 2026-09-07, same day the shared monitoring/ingress stack was
  migrated onto `system-m8a` and this study's AIPerf Job followed suit — see the
  study's top-level README and `infra/README.md`).

## Telemetry

Full 98-metric catalog carried over unchanged from `5-pack-changes` (the original
TTFT/ITL/throughput/saturation/KV-cache/sequence-length/fleet catalog, the 23 GPU/DCGM
metrics, 25 Kubernetes Container metrics x2 components, 5 Kubernetes Cluster PSI
metrics x2 components) — no new metrics added, no query changes, since the
scoping mechanism (component-instance property substitution) doesn't depend on which
specific node group a component's `node_role`/`pod` property points at.

## Workflow: `6-Data-Parallelism-Workflow`

Same three-task shape as `2-larger-model-g7e`: `Write config` (FileConfigurator),
`Apply config` (Executor, `apply_config.sh`, 75m timeout — model load time, unrelated
to the load-test change), `RunTest` (Executor, `run_test_goodput.sh`, **105m timeout**
— restored to match the 12-level sweep's own `kubectl wait` of 5700s/95m, since this
study runs the same ramp as `2-larger-model-g7e`, not `5-pack-changes`' flat load).

## Study: `6-Data-Parallelism`

- **Goal**: maximize `vLLM.prefill_token_throughput + vLLM.decode_token_throughput`,
  subject to `vLLM.time_to_first_token_p95 <= 1500` and
  `vLLM.inter_token_latency_p95 <= 300` — identical to `2-larger-model-g7e`.
- **Windowing**: `stability` on `vLLM.prefill_token_throughput` (max), `width: 6` —
  identical to `2-larger-model-g7e` (restored from `5-pack-changes`' `trim` windowing,
  since this study runs the real concurrency ramp again, not a flat load).
- **No `parametersSelection`/`parameterConstraints`** — this study runs exactly 4
  fixed configurations, not an optimizer search, so there's nothing to select a
  domain for and no domain to constrain (same reasoning `4-goodput-extended` used for
  its own baseline+preset design).
- **`baseline` step**: identical to `2-larger-model-g7e`'s (`doNotRenderParameters` for
  all 25 non-pinned parameters, only `gpu_memory_utilization: 0.90` explicitly set) —
  `data_parallel_size` stays unrendered here too (vLLM's own default, 1 GPU used,
  despite the pod requesting all 4).
- **`preset_dp2`/`preset_dp3`/`preset_dp4` steps**: byte-for-byte identical to
  `baseline` (same `values`/`doNotRenderParameters`) except `vLLM.data_parallel_size`
  moves from `doNotRenderParameters` into `values` with an explicit `2`/`3`/`4` — the
  ONLY variable across all 4 steps. See the study's top-level README, "Study design,"
  for the full 4-row table.
- **No `optimize` step** — this study only ever runs these 4 trials (one per step,
  `numberOfTrials: 1` each).

## Validation performed

Structurally consistent with `2-larger-model-g7e` (goal/constraints/windowing/
baseline copied verbatim; `steps` replaced with the 4-preset `data_parallel_size`
design — see study README "Study design" — confirmed each preset's
`doNotRenderParameters` list matches baseline minus exactly `vLLM.data_parallel_size`,
no drift) and with `5-pack-changes` (component/telemetry catalog copied verbatim, only
`node_role` re-pointed). Real
instance specs for `g6.12xlarge` (48 vCPU, 192GiB RAM, 4x L4 @ 22888MiB each) and
`m8a.xlarge` (4 vCPU, 16GiB RAM) were verified live via `aws ec2
describe-instance-types` before sizing `k8s/01-deployment_template.yaml`'s resources
and `infra/eks/cluster.yaml`'s `system-m8a` node group. **Not yet validated against a
live `akamas create -f`**, and **the `llm-serving-l4` node group does not exist yet on
the live cluster** — provision it first (see `infra/README.md`), and re-confirm all
three pack versions (see "Versions" above).

## Placeholders left — fill in before running

- **`akamas/id_rsa`** — deliberately excluded from this scaffold. Supply your own
  `toolbox` host SSH key at this path — do not copy one from another study folder
  (see this repo's own git history for why that's specifically caused problems).
- **vLLM image tag**: `k8s/01-deployment_template.yaml` pins `vllm/vllm-openai:v0.22.0`
  — unchanged from `2-larger-model-g7e`, unverified on L4.
- **Concurrency**: `k8s/05-job.yaml`'s 12-level ramp (150→1024) — carried forward from
  `2-larger-model-g7e`/`1-goodput-realistic-load`, calibrated on A10G, not
  independently recalibrated for L4.
- **`llm-serving-l4` node group** — created 2026-09-07, `desiredCapacity: 0`. Scale it
  up and verify `nvidia.com/gpu: 4` before trusting a real run (see top-level README's
  "Not done yet").
- **`system-m8a` node group** — created AND migrated to the same day (see top-level
  README's "system node group replacement — DONE").

## Setup & run

```bash
# Confirm all three installed pack versions first (see "Versions" above)
akamas describe optimization-pack vLLM
akamas describe optimization-pack GPU
akamas describe optimization-pack "Kubernetes"

# Typed, per-resource form (dependency order matters)
akamas create system             studies/6-data-parallelism/akamas/system.yaml
akamas create component          studies/6-data-parallelism/akamas/components/container.yaml          "vLLM_Benchmark_6_Data_Parallelism"
akamas create component          studies/6-data-parallelism/akamas/components/container_loadtest.yaml "vLLM_Benchmark_6_Data_Parallelism"
akamas create component          studies/6-data-parallelism/akamas/components/gpu.yaml                "vLLM_Benchmark_6_Data_Parallelism"
akamas create component          studies/6-data-parallelism/akamas/components/vllm.yaml               "vLLM_Benchmark_6_Data_Parallelism"
akamas create component          studies/6-data-parallelism/akamas/components/cluster.yaml            "vLLM_Benchmark_6_Data_Parallelism"
akamas create component          studies/6-data-parallelism/akamas/components/cluster_loadtest.yaml   "vLLM_Benchmark_6_Data_Parallelism"
akamas create telemetry-instance studies/6-data-parallelism/akamas/telemetry/prometheus.yaml "vLLM_Benchmark_6_Data_Parallelism"
akamas create workflow           studies/6-data-parallelism/akamas/6-Data-Parallelism-Workflow.yaml
akamas create study              studies/6-data-parallelism/akamas/6-Data-Parallelism.yaml

akamas start study "6-Data-Parallelism"
```

Or, bulk form (same dependency order still applies internally — every file
self-describes its `kind:`/`system:`):

```bash
akamas create -f studies/6-data-parallelism/akamas/
akamas start study "6-Data-Parallelism"
```
