# 9-Goodput-Per-GPU

**Status:** TODO
**Dates:** Scaffolded 2026-09-10

## Objective

Same search as `8-parallelism-tuning` — 16 tuned vLLM parameters including
`tensor_parallel_size`/`data_parallel_size` in [1, 4] on one `g6.12xlarge` (4x NVIDIA L4)
serving `Qwen/Qwen2.5-7B-Instruct` — but a different objective: maximize **goodput per
GPU actually used**,

```
(vLLM.prefill_token_throughput + vLLM.decode_token_throughput) / vLLM.active_gpus
```

subject to the same P95 TTFT ≤ 1500 ms / P95 ITL ≤ 300 ms SLA. `8-parallelism-tuning`
answers "how much goodput can this node give" and is naturally won by whatever occupies
all four GPUs; this study asks "which configuration extracts the most goodput from each
GPU it occupies", so a TP=4 or DP=4 configuration has to deliver 4x a single-GPU
configuration to score the same. Together the two studies measure TP/DP scaling
efficiency directly (ROADMAP H5: ~3.5x for 4 GPUs is the well-optimized ballpark).

`vLLM.active_gpus` is a new metric (vLLM optimization pack **1.8.0**) — see "The two new
metrics" below. It is constant within a trial (weights are loaded once), so dividing by
it does not interact with the `stability` windowing.

## The three new metrics (vLLM pack 1.8.0, `akamas/telemetry/prometheus.yaml`)

| Metric | Query | Equals | In goal? |
|---|---|---|---|
| `vLLM.active_gpus` | `count(DCGM_FI_DEV_FB_USED{exported_pod=~"$POD$"} > 1024)` | TP × DP — GPUs holding model weights (> 1 GiB framebuffer; an idle L4 reads ~2 MiB) | **yes** |
| `vLLM.active_dp_engines` | `count(count by (engine) (vllm:cache_config_info{pod=~"$POD$"}))` | DP — one `vllm:cache_config_info` series per data-parallel engine (`engine="0","1",…`) | no — TP=4/DP=1 would read 1 and hide 4 GPUs; kept so TP = active_gpus / active_dp_engines |
| `vLLM.gpu_memory_allocated_gb` | `sum(DCGM_FI_DEV_FB_USED{exported_pod=~"$POD$"} > 1024) * 1048576 / 1e9` | GPU memory vLLM occupies across its GPUs, decimal GB (same unit as `kv_cache_capacity_gb`); ≈ `gpu_memory_utilization × active_gpus × 23 034 MiB` on L4 | no — observability: memory cost of each topology next to its KV capacity |

Why DCGM for the GPU count: vLLM exposes no metric carrying its TP degree, so the only
way to count GPUs that also sees tensor parallelism is the hardware side. All three queries
were **verified live on 2026-09-10** against the pod running `8-parallelism-tuning`'s
experiment 2 (`--tensor-parallel-size=1 --data-parallel-size=3`): the two counts return **3**,
`gpu_memory_allocated_gb` returns **64.06** (3 × 20 364 MiB); DCGM showed `gpu0/1/2` at
20 364 MiB and `gpu3` at 2 MiB.

Label caveat, also verified: on the DCGM series scraped through the Prometheus Operator,
`pod` is the **dcgm-exporter's own pod**; the GPU-consuming pod is `exported_pod`
(`exported_namespace`, `exported_container` likewise). `active_gpus` therefore filters
on `exported_pod`. The 38 pre-existing DCGM queries in this catalog filter on
`pod=~"$POD$"` and only work because every GPU component has `pod: .*`.

**"Total KV cache available" is not a new metric** — it is pack 1.7.0's
`kv_cache_capacity_tokens` (exact: `num_gpu_blocks × block_size`, engine-summed by vLLM's
own API server, so 172 512 tokens at DP=3 = 3 × 57 504) and `kv_cache_capacity_gb` (via
the sidecar's bf16 bytes-per-token constant — 2× too high on fp8 trials, see caveats).
Both already in this catalog. What was broken: the `kv-cache-exporter` sidecar published
capacity only once `vllm:kv_cache_usage_perc` had samples, and with
`data_parallel_size > 1` that gauge has none until the first request is served (verified
2026-09-10: DP=3 pod idle for hours, `vllm_kv_cache_exporter_scrape_success 0`, while at
DP=1 the gauge exists from startup). **Fixed 2026-09-10** in
`k8s/04-kv-cache-exporter-configmap.yaml` (and `8-parallelism-tuning`'s identical copy):
capacity gauges are published as soon as `vllm:cache_config_info` exists, usage/used
gauges only when usage samples exist — nothing stale is ever exported. Tested against
three fixtures (idle DP=3 → capacity only; busy → usage mean 1/3, used 57 504; nothing →
no gauges); the live ConfigMap `llm-serving/kv-cache-exporter` was re-applied and takes
effect at the next pod rollout (i.e. the next trial).

Assumption: the GPU node is dedicated to the vLLM pod (it is — `llm-serving-l4` is
tainted for it). Any other GPU workload on the node would inflate `active_gpus`.

## DCGM counter set aligned with NVIDIA's GPU-profiling reference (2026-09-10)

`k8s/monitoring/dcgm_counters.csv` was diffed against NVIDIA's Run:ai ["GPU profiling
metrics"](https://run-ai-docs.nvidia.com/saas/platform-management/monitor-performance/gpu-profiling-metrics)
page (33 DCGM fields; distilled in `knowledge/notes/2026-09-nvidia-dcgm-gpu-profiling-metrics.md`).
30 were already exported; the 3 missing ones — `DCGM_FI_DEV_NVLINK_BANDWIDTH_L0`,
`DCGM_FI_PROF_NVLINK_TX_BYTES`, `DCGM_FI_PROF_NVLINK_RX_BYTES` — were added to the CSV
(here and in `8-parallelism-tuning`'s identical copy, since the exporter's ConfigMap
`monitoring/dcgm-custom-metrics` is shared), to the GPU pack as **1.2.0**
(`gpu_nvlink_bandwidth_l0`, `gpu_nvlink_tx_bytes`, `gpu_nvlink_rx_bytes`, branch
`feature/nvlink-profiling-counters`) and to this study's telemetry on the four GPU
components. **On this node they publish nothing**: the L4 has no NVLink (`dcgm-exporter`:
"Failed to initialize NvSwitch/NvLink info: no switches to monitor"), exactly like the
pre-existing `gpu_nvlink_bandwidth_total`. Found on the way: the live ConfigMap carried
`DCGM_FI_DEV_POWER_VIOLATION`/`DCGM_FI_DEV_THERMAL_VIOLATION` (needed by
`gpu_power_violation_rate`/`gpu_thermal_violation_rate`) that no study's CSV listed —
re-applying the ConfigMap from the repo dropped them once on 2026-09-10; both are now in
the CSV (copied verbatim from the live ConfigMap) and re-applied. The 12 extra counters
we export beyond NVIDIA's page (`FB_TOTAL/RESERVED/USED_PERCENT`, `POWER_MGMT_LIMIT`,
`CLOCK_THROTTLE_REASONS`, `PSTATE`, `SLOWDOWN_TEMP`, `FAN_SPEED`, `COUNT`, identity
labels) stay.

## Percent metrics: the 850% PSI bug and the 0-1 ratio convention (2026-09-10)

PSI metrics showed values like **850%** in Akamas. Cause: Akamas' `percent` unit is a
**0-1 ratio** — every reference query in Akamas' own Prometheus metrics mapping
(`container_cpu_util`, `container_memory_util`, Linux `cpu_util`, `jvm_heap_util`) returns a
plain ratio and the UI renders it ×100; the vLLM pack's `kv_cache_usage_*` (0-1) display
correctly for the same reason. The Kubernetes-pack percent queries this repo wrote in
`5-pack-changes` prefixed `100 *`, so a real 8.5% CPU stall (Prometheus: max 15.4% over two
days on the L4 node, ≤ 10% on the vLLM container) displayed as 850%. Fixed in this study's
`akamas/telemetry/prometheus.yaml`:
- **16 queries lost their `100 *`**: the 11 PSI (`k8s_cluster_*_pressure*`,
  `container_*_pressure_*`) plus `container_cpu_util`, `container_cpu_util_max`,
  `container_cpu_throttle_time`, `container_memory_util`, `container_memory_util_max`.
- **5 DCGM queries now divide by 100** — the opposite defect: `DCGM_FI_DEV_GPU_UTIL`,
  `MEM_COPY_UTIL`, `ENC_UTIL`, `DEC_UTIL`, `FAN_SPEED` are 0-100 natively (a 96% `gpu_util`
  displayed as 9600%). `FB_USED_PERCENT` and every `PROF_*` field are already 0-1 (verified:
  `FB_USED_PERCENT` = 0.986 at baseline, `GPU_UTIL/100` = 1.0 under load) and are untouched.
- `container_cpu_throttled_millicores` re-pointed at Akamas' reference query
  `1e3 * rate(container_cpu_cfs_throttled_seconds_total)` — it used `100 * rate(...throttled_periods_total)`,
  the wrong counter and the wrong factor. Note it stays **empty on this cluster**: kube-prometheus-stack's
  kubelet ServiceMonitor drops `container_cpu_cfs_throttled_seconds_total` by default; a correct
  empty metric beats a wrong number, and no container here has `limits.cpu` anyway.
Pack side: Kubernetes pack **1.8.1-dev** (branch `feature/psi-ratio-convention`) and GPU pack
1.2.0 (same branch as the NVLink counters) only clarify descriptions — no metric renamed, no
unit changed, no reinstall needed for the numbers to be right. Studies 5/7/8 still carry the
old scale in their telemetry instances; recreating those instances with the corrected queries
is the fix if their values are ever compared with this study's.

## Study design

Identical to `8-parallelism-tuning` — read that README for the full rationale:
- 16 tuned parameters (its 14 + TP/DP in [1, 4]), same domains;
- 5 `parameterConstraints` — 3 vLLM-wide attention-backend/`kv_cache_dtype` rules,
  `TP × DP ≤ 4`, `TP ≠ 3` (28 attention heads / 4 KV heads) → 7 valid topologies;
- `baseline`: `gpu_memory_utilization: 0.90` pinned, all else unrendered (TP1/DP1 →
  `active_gpus = 1`, so baseline score = raw goodput);
- `optimize`: 1000 experiments / 200 failures.

## Stack & versions

- **Akamas:** 3.7.1 (`akamas.lab.akamas.io`, workspace `default`), CLI 3.0.1 in the
  `toolbox` pod (its login expires roughly daily — `akamas login` before using it).
- **Optimization packs:** vLLM **1.8.0** (adds `active_gpus`, `active_dp_engines`,
  `gpu_memory_allocated_gb` on top of 1.7.0's absolute KV-cache metrics — **not yet built/installed**, see "Prerequisites"),
  GPU **1.2.0** (adds `gpu_nvlink_bandwidth_l0`, `gpu_nvlink_tx_bytes`, `gpu_nvlink_rx_bytes` —
  **not yet built/installed** either; installed is 1.1.0), Kubernetes 1.8.0-dev.
- **Workload, cluster, load generator, telemetry:** as `8-parallelism-tuning` —
  `vllm/vllm-openai:v0.22.0`, `Qwen/Qwen2.5-7B-Instruct`, EKS `vllm-bench` node group
  `llm-serving-l4` (1x `g6.12xlarge`), AIPerf 12-level ramp 150→1024, Prometheus
  instance `Prometheus_9_Goodput_Per_GPU` with **108** metrics (102 + the three above + the
  three NVLink ones below).

## Known caveats

Everything in `8-parallelism-tuning`'s "Known caveats" applies unchanged — in particular:
- `kv_cache_*_gb` read 2× too high on fp8 trials (fixed bf16 constant in the sidecar);
- **shares every Kubernetes object with studies 7 and 8** (`llm-serving/vllm`,
  `llm-benchmark/aiperf-benchmark`) — only one of them can run at a time;
- the model-cache PV is AZ-bound while the node group spans 3 AZs — a scale-from-zero
  that lands in another AZ leaves the pod `Pending` until the PVC is recreated (hit twice
  on 2026-09-09/10, see that README);
- concurrency ramp calibrated on 1x A10G.

Specific to this goal: dividing by `active_gpus` means a configuration whose weights
have not finished loading when the window opens would divide by a smaller count — not a
real risk here, since the `stability` window is selected on `prefill_token_throughput`,
which is zero until the model serves.

## Parameters tuned

Same 16 as `8-parallelism-tuning` (see that README's table) — unchanged domains,
baseline values and constraints.

## Prerequisites before this study can be started

1. **vLLM pack 1.8.0 and GPU pack 1.2.0 built and installed** — the telemetry instance references
   `active_gpus`/`active_dp_engines` and `akamas create telemetry-instance` fails with
   "metric(s) are not present in System" against 1.7.0 (exactly what happened to study 7
   against 1.6.1). Build from the pack clone that carries **both** the 1.7.0 KV-cache
   metrics and the 1.8.0 additions — a 1.8.0 built from `develop` (1.6.1) would drop the
   4 `kv_cache_*` metrics studies 8 and 9 also use.
2. `llm-serving-l4` up with `nvidia.com/gpu: 4` and the model-cache PV in the node's AZ.
3. No other study running against `llm-serving`.
4. `akamas/id_rsa` on the `toolbox` host at
   `/work/vllm-benchmark/studies/9-goodput-per-gpu/akamas/id_rsa` (never in git).

## How to run

```bash
# in the toolbox pod, /work/vllm-benchmark, after `akamas login`
akamas build optimization-pack /work/vllm-180                 # writes vLLM_1-8-0.json
akamas install -f optimization-pack vLLM_1-8-0.json
akamas describe optimization-pack vLLM | grep -E 'version|active_gpus|active_dp_engines|gpu_memory_allocated_gb'
akamas build optimization-pack /work/nvidia-gpu-120           # writes GPU_1-2-0.json
akamas install -f optimization-pack GPU_1-2-0.json
akamas describe optimization-pack GPU  | grep -E 'version|gpu_nvlink'

akamas create -f studies/9-goodput-per-gpu/akamas/
akamas describe study "9-Goodput-Per-GPU"
akamas start study "9-Goodput-Per-GPU"
```

## Results

<Filled in by the study-recap skill once the study finishes.>

## Conclusions

<Filled in by the study-recap skill once the study finishes.>
