# 6-Data-Parallelism — Akamas resources

**Created:** 2026-09-07 (scaffolded from `5-pack-changes`, config aligned to
`2-larger-model-g7e`)

**Last modified:** 2026-09-08 — GPU modeled as **one component per GPU**
(`components/gpu0.yaml`–`gpu3.yaml`, `prometheus.gpu: "0".."3"`) replacing the single
`gpu` component (`gpu: .*`), and the 38 per-GPU DCGM queries in
`telemetry/prometheus.yaml` lost their `by(gpu)` grouping — each now returns one series
per component, so every DCGM metric shows up in Akamas per GPU instance instead of one
series aggregated across the 4 L4s. Study/workflow files renamed to the `7-` prefix the
same day. On an already-created system: delete component `gpu`, create the four new
ones, delete and recreate the telemetry instance — see "Setup & run".

**Also 2026-09-08 (later the same day):** 4 **absolute KV-cache metrics**
(`kv_cache_capacity_tokens`, `kv_cache_used_tokens`, `kv_cache_capacity_gb`,
`kv_cache_used_gb` — vLLM pack **1.6.1 → 1.7.0**, branch
`feature/kv-cache-absolute-metrics`, not yet built/installed) added to
`telemetry/prometheus.yaml` (98 → 102 metrics). They need a new `kv-cache-exporter`
sidecar in the vLLM pod (`k8s/04-kv-cache-exporter-configmap.yaml`,
`k8s/01-deployment_template.yaml`, `k8s/02-service.yaml`, `k8s/monitoring/
servicemonitor.yaml`) — see "Telemetry" for why vLLM alone can't provide them.

Measures **goodput** — `vLLM.prefill_token_throughput + vLLM.decode_token_throughput`
subject to a P95 TTFT ≤ 1500ms / P95 ITL ≤ 300ms SLA — for `Qwen/Qwen2.5-7B-Instruct`,
served by vLLM on a new node group (`llm-serving-l4`, g6.12xlarge, 4x NVIDIA L4 24GB).
Not a tuning study: 4 fixed-configuration steps (`baseline` + 3 `preset`) that vary
**only** `vLLM.data_parallel_size` (1/2/3/4), no optimize step, no
`parametersSelection`/`parameterConstraints` — goal/windowing/model/load pattern are
otherwise identical to `2-larger-model-g7e`. The full 102-metric telemetry catalog (98 carried over + 4 absolute KV-cache metrics, 2026-09-08) and
all components from `5-pack-changes` (6 there, 9 here — the single `gpu` component was
split into `gpu0`–`gpu3` on 2026-09-08; DCGM, PSI cluster/container, both scoped to
this study's own node group) are carried over, just re-pointed to `llm-serving-l4`.

## Versions

- **vLLM optimization pack**: **1.7.0** (bumped 2026-09-08 on
  `feature/kv-cache-absolute-metrics`, uncommitted in the local pack clone as of that
  date — 4 new metrics `kv_cache_capacity_tokens`/`kv_cache_used_tokens`/
  `kv_cache_capacity_gb`/`kv_cache_used_gb`; 1.6.1 was `feature/mfu-compute-bandwidth-
  metrics`, 2026-09-07). **TODO: build + install, then re-verify**: `akamas describe
  optimization-pack vLLM` must show 1.7.0 or the 4 KV-cache entries in
  `telemetry/prometheus.yaml` won't resolve.
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

9 components — the 6 from `5-pack-changes` re-pointed to this study's own node group,
with the single `gpu` component split into four on 2026-09-08:
- `vLLM` → `vLLM` (`prometheus.{pod,model}: .*`, unchanged).
- **`gpu0`, `gpu1`, `gpu2`, `gpu3` → `GPU`** (`prometheus.pod: .*`,
  **`prometheus.gpu: "0"`/`"1"`/`"2"`/`"3"`** — the DCGM `gpu` label, i.e. the device
  index of each of the node's 4 L4s). Replaces `5-pack-changes`' single `gpu`
  component (`gpu: .*`), which handed all four GPUs' series to one component and so
  showed one aggregated series per metric. Quoted strings on purpose; PromQL regex
  matchers are anchored, so `gpu=~"0"` matches only index 0.
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

102 metrics: the 98-metric catalog carried over unchanged from `5-pack-changes` (the original
TTFT/ITL/throughput/saturation/KV-cache/sequence-length/fleet catalog, the 23 GPU/DCGM
metrics, 25 Kubernetes Container metrics x2 components, 5 Kubernetes Cluster PSI
metrics x2 components) plus the 4 absolute KV-cache metrics below (2026-09-08). The
98 needed no query changes, since the scoping mechanism (component-instance property
substitution) doesn't depend on which specific node group a component's
`node_role`/`pod` property points at.

**Per-GPU split (2026-09-08):** GPU metrics are now split per GPU instance by
modeling one component per GPU (see "System"), not by label. Every per-GPU DCGM query
had been grouped `<agg> by(gpu)(...)`, which returned four series to the single `gpu`
component and collapsed into one aggregated value; the grouping is removed on all 38
entries (`avg(...)`/`sum(...)`/`max(...)`/`min(...)` over `gpu=~"$GPU$"`), so with
`$GPU$` bound to one index per component each query returns exactly one series for that
GPU. Metric names and count are unchanged (98). `gpu_count` (`DCGM_FI_DEV_COUNT`)
returns the node's device count (4) on every GPU component — expected. The vLLM
`*_per_gpu` MFU metrics are vLLM-sourced, not DCGM, and untouched. **Not yet verified
live** (Akamas endpoint unreachable 2026-09-08). Pre-run check that DCGM's `gpu` label
really is `0`–`3` on this node (exporter default, never looked at on this node yet):

```promql
count by(gpu)(DCGM_FI_DEV_GPU_UTIL)
```

**Absolute KV-cache metrics (2026-09-08):** `kv_cache_usage_avg`/`_max` are ratios, so
they can't be compared across the 4 steps of this study — every `tensor_parallel_size`
gives the KV cache a different capacity. vLLM `v0.22.0` exports KV-cache usage only as
that ratio (`vllm:kv_cache_usage_perc`) and the capacity only as **string labels** on
the info gauge `vllm:cache_config_info` (`num_gpu_blocks`, `block_size`; verified in
`vllm/v1/metrics/loggers.py` and `vllm/v1/engine/core_client.py` at tag `v0.22.0` — the
API server does hold the real, engine-summed `num_gpu_blocks`). PromQL has no
label-to-number conversion, so a Prometheus query alone can't produce an absolute value.
A stdlib-Python **`kv-cache-exporter` sidecar** in the vLLM pod
(`k8s/04-kv-cache-exporter-configmap.yaml` + container in
`k8s/01-deployment_template.yaml`, port 9400 via `k8s/02-service.yaml`, scraped by a
second endpoint in `k8s/monitoring/servicemonitor.yaml`) reads vLLM's own `/metrics` on
localhost and republishes numeric gauges; the 4 new entries in
`telemetry/prometheus.yaml` read those:

| Metric | Query | Exact? |
| --- | --- | --- |
| `kv_cache_capacity_tokens` | `sum(vllm_kv_cache_capacity_tokens{pod=~"$POD$"})` | yes — `num_gpu_blocks x block_size` |
| `kv_cache_used_tokens` | `sum(vllm_kv_cache_used_tokens{pod=~"$POD$"})` | yes — `capacity x mean(kv_cache_usage_perc)` |
| `kv_cache_capacity_gb` | `sum(vllm_kv_cache_capacity_bytes{pod=~"$POD$"}) / 1e9` | depends on bytes/token constant |
| `kv_cache_used_gb` | `sum(vllm_kv_cache_used_bytes{pod=~"$POD$"}) / 1e9` | depends on bytes/token constant |

Bytes per token = 2 x layers x KV heads x head_dim x dtype bytes = 2 x 28 x 4 x 128 x 2
= **57344** for Qwen2.5-7B-Instruct with a bf16 KV cache (HF `config.json`), set as env
vars on the sidecar; it assumes `kv_cache_dtype` stays unrendered (auto → bf16) and
TP ≤ 4 (KV heads sharded, not replicated). The sidecar publishes nothing (not stale
values) until vLLM has started, so `sum()` yields no datapoint rather than a wrong one.
The exporter was tested locally against a fixture of vLLM's `/metrics` text (parsing,
arithmetic, and the unreachable → not-ready → ready → gone transitions); the real
scrape, the pack build/install and the Akamas create are **not yet verified live**.

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
# 0. vLLM pack 1.7.0 (absolute KV-cache metrics, 2026-09-08) — build + install BEFORE
#    creating the telemetry instance. Run from this repo's root: the pack clone is
#    the sibling folder ../optimization-packs/vllm (i.e. ~/akamas/offline/
#    optimization-packs/vllm), branch feature/kv-cache-absolute-metrics. Verified
#    2026-09-08: this build succeeds locally and writes vLLM_1-7-0.json into the cwd.
akamas build optimization-pack ../optimization-packs/vllm
akamas install -f optimization-pack <JSON written by the build command>   # -f = upgrade over 1.6.1
akamas describe optimization-pack vLLM                                     # expect 1.7.0, kv_cache_capacity_tokens etc.

# 1. Kubernetes one-time applies for the kv-cache-exporter sidecar (2026-09-08) —
#    a missing ConfigMap leaves the vLLM pod in ContainerCreating until the rollout
#    times out; the Service/ServiceMonitor re-applies add the :9400 scrape.
kubectl apply -f studies/7-tensor-parallelism/k8s/04-kv-cache-exporter-configmap.yaml
kubectl apply -f studies/7-tensor-parallelism/k8s/02-service.yaml
kubectl apply -f studies/7-tensor-parallelism/k8s/monitoring/servicemonitor.yaml

# 2. Confirm all three installed pack versions (see "Versions" above)
akamas describe optimization-pack vLLM
akamas describe optimization-pack GPU
akamas describe optimization-pack "Kubernetes"

# 3. Typed, per-resource form (dependency order matters)
akamas create system             studies/7-tensor-parallelism/akamas/system.yaml
akamas create component          studies/7-tensor-parallelism/akamas/components/container.yaml          "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create component          studies/7-tensor-parallelism/akamas/components/container_loadtest.yaml "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create component          studies/7-tensor-parallelism/akamas/components/gpu0.yaml               "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create component          studies/7-tensor-parallelism/akamas/components/gpu1.yaml               "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create component          studies/7-tensor-parallelism/akamas/components/gpu2.yaml               "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create component          studies/7-tensor-parallelism/akamas/components/gpu3.yaml               "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create component          studies/7-tensor-parallelism/akamas/components/vllm.yaml               "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create component          studies/7-tensor-parallelism/akamas/components/cluster.yaml            "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create component          studies/7-tensor-parallelism/akamas/components/cluster_loadtest.yaml   "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create telemetry-instance studies/7-tensor-parallelism/akamas/telemetry/prometheus.yaml "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create workflow           studies/7-tensor-parallelism/akamas/7-Tensor-Parallelism-Workflow.yaml
akamas create study              studies/7-tensor-parallelism/akamas/7-Tensor-Parallelism.yaml

akamas start study "7-Tensor-Parallelism"
```

Or, bulk form (same dependency order still applies internally — every file
self-describes its `kind:`/`system:`):

```bash
akamas create -f studies/7-tensor-parallelism/akamas/
akamas start study "7-Tensor-Parallelism"
```

### Applying the 2026-09-08 changes (per-GPU components, absolute KV-cache metrics) to an already-created system

There is no update verb for components or telemetry instances — the old `gpu`
component must be deleted, the four new ones created, and the telemetry instance
deleted and recreated (its queries changed, and it now references 4 metrics that only
exist in vLLM pack 1.7.0 — install that first, step 0 above, plus the kubectl applies
of step 1). System, other components, workflow and study are untouched. Do this before
starting the study; metrics already collected by earlier trials are not re-fetched.

```bash
akamas delete component "gpu" "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create component "studies/7-tensor-parallelism/akamas/components/gpu0.yaml" "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create component "studies/7-tensor-parallelism/akamas/components/gpu1.yaml" "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create component "studies/7-tensor-parallelism/akamas/components/gpu2.yaml" "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create component "studies/7-tensor-parallelism/akamas/components/gpu3.yaml" "vLLM_Benchmark_7_Tensor_Parallelism"
akamas delete telemetry-instance "Prometheus_7_Tensor_Parallelism" "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create telemetry-instance studies/7-tensor-parallelism/akamas/telemetry/prometheus.yaml "vLLM_Benchmark_7_Tensor_Parallelism"
akamas list component "vLLM_Benchmark_7_Tensor_Parallelism"             # expect gpu0..gpu3, no gpu
```
