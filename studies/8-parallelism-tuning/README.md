# 8-Parallelism-Tuning

**Status:** TODO
**Dates:** Scaffolded 2026-09-09

## Objective

Maximize **goodput** — `vLLM.prefill_token_throughput + vLLM.decode_token_throughput`
subject to P95 TTFT ≤ 1500 ms and P95 ITL ≤ 300 ms — for `Qwen/Qwen2.5-7B-Instruct`
served by vLLM on one `g6.12xlarge` node (4x NVIDIA L4 24 GB, Ada Lovelace/SM89, PCIe
only, no NVLink), letting the optimizer **search the 4-GPU topology itself**:
`vLLM.tensor_parallel_size` and `vLLM.data_parallel_size` are tuned parameters here,
alongside the same 14 per-instance vLLM parameters `2-larger-model-g7e` tunes.

This tests `ROADMAP.md` **H5**'s second angle directly — "given N total GPUs, which
TP/replica split wins" — and **H6** (TP frees per-GPU KV headroom that lets
`max_num_seqs` run higher, a coupling only visible when both are searched together).
`7-tensor-parallelism` on the same hardware runs the split as fixed presets (DP 1..4,
TP 2/4) with every other parameter at vLLM's default; this study instead co-tunes the
split with the 14 per-instance parameters and lets the optimizer find the combination.

## Study design

- **16 tuned parameters** (see "Parameters tuned"): the 14 of `2-larger-model-g7e`
  (goal, SLA constraints, windowing, domains and `optimize` step carried over verbatim)
  plus `tensor_parallel_size` ∈ [1, 4] and `data_parallel_size` ∈ [1, 4].
- **5 `parameterConstraints`**: the 3 vLLM-wide attention-backend/`kv_cache_dtype` rules
  `2-larger-model-g7e` root-caused on real failures, plus 2 new **topology** rules —
  `TP × DP ≤ 4` (the pod requests exactly `nvidia.com/gpu: "4"`) and `TP ≠ 3` (Qwen2.5-7B
  has 28 attention heads / 4 KV heads, read from its `config.json` on the cluster; 3
  divides neither, so vLLM refuses to start). Only **7 of the 16** (TP, DP) pairs are valid:

  | TP \ DP | 1 | 2 | 3 | 4 |
  |---|---|---|---|---|
  | **1** | ✓ 1 GPU | ✓ 2 replicas | ✓ 3 replicas | ✓ 4 replicas |
  | **2** | ✓ 2 GPUs | ✓ 2×2 | ✗ 6 GPUs | ✗ 8 GPUs |
  | **3** | ✗ heads | ✗ | ✗ | ✗ |
  | **4** | ✓ 4 GPUs | ✗ 8 GPUs | ✗ | ✗ |

- **`baseline` step**: identical design to `2-larger-model-g7e`/`7-tensor-parallelism` —
  only `gpu_memory_utilization: 0.90` pinned, every other vLLM parameter (the 15 other
  tuned ones **including TP/DP**, plus the 10 pinned template tokens) in
  `doNotRenderParameters`, so vLLM runs its own defaults: **TP 1 / DP 1, one GPU used,
  three idle** (the per-GPU DCGM components `gpu1`–`gpu3` will show it).
- **`optimize` step**: `numberOfExperiments: 1000`, `maxFailedExperiments: 200`, as
  `2-larger-model-g7e`. No `doNotRenderParameters` on it — all 16 render every trial.

## Stack & versions

- **Akamas version:** 3.7.1 (`akamas.lab.akamas.io`, workspace `default`; CLI 3.0.1 in
  the `toolbox` pod).
- **Optimization packs:** vLLM **1.7.0** (`feature/kv-cache-absolute-metrics`, built +
  installed 2026-09-08 from the `toolbox` pod — still **uncommitted** in the local pack
  clone, see `7-tensor-parallelism/README.md`), GPU **1.1.0**, Kubernetes **1.8.0-dev**.
  All three verified installed 2026-09-08 with `akamas describe optimization-pack`.
- **Workload under test:** `vllm/vllm-openai:v0.22.0` serving `Qwen/Qwen2.5-7B-Instruct`
  (bf16 weights; `kv_cache_dtype` is tuned), Deployment `vllm` in namespace
  `llm-serving`, plus the `kv-cache-exporter` sidecar (port 9400) —
  `k8s/01-deployment_template.yaml`, unchanged from `7-tensor-parallelism`.
- **Cluster / hardware:** EKS `vllm-bench` (us-east-2), node group `llm-serving-l4`
  (1x `g6.12xlarge`, 4x L4 24 GB, `nvidia.com/gpu: 4` verified 2026-09-08), load test
  on `system-m8a` (`m8a.xlarge`) — `infra/` is a verbatim copy of `7-tensor-parallelism`'s
  (same cluster, nothing new to provision).
- **Load generator:** NVIDIA AIPerf (`k8s/05-job.yaml`, unchanged): ShareGPT replay,
  12-level concurrency ramp 150→1024, 300 s/level, `kubectl wait` 5700 s.
- **Telemetry:** Prometheus (`kube-prometheus-stack`), instance
  `Prometheus_8_Parallelism_Tuning`, 102 metrics on 9 components — `7-tensor-parallelism`'s
  catalog with the two fixes below.

## Differences from `7-tensor-parallelism`

Everything not listed here is a verbatim copy (components, k8s manifests, scripts,
infra) with the folder/resource names changed to `8-parallelism-tuning` /
`8-Parallelism-Tuning` / `vLLM_Benchmark_8_Parallelism_Tuning` /
`Prometheus_8_Parallelism_Tuning` / `8-Parallelism-Tuning-Workflow`.

1. **Optimizer search instead of presets** — `parametersSelection` (16),
   `parameterConstraints` (5) and an `optimize` step, as described above.
2. **Two telemetry-query fixes** (applied only here, found by running all 102 queries
   against the live Prometheus on 2026-09-08 — see `akamas/README.md` "Telemetry"):
   `${percentile}` → `0.95` in `fleet_e2e_latency_percentile` /
   `fleet_inter_token_latency_percentile` (Grafana syntax, rejected by Prometheus with a
   parse error — those two metrics never collected a datapoint in any study of this
   repo), and a fixed `[2m]` window in the 5 `k8s_cluster_*_pressure*` PSI queries
   (`node-exporter` scrapes every 30 s, so `rate(...[30s])` — `$DURATION$` at
   `duration: 30` — returned nothing). Other studies still carry both issues.
3. **No `01-deployment.yaml`** committed — it's FileConfigurator's rendered output.

## Known caveats (read before the first run)

- **`kv_cache_capacity_gb` / `kv_cache_used_gb` are wrong on fp8 trials.** The
  `kv-cache-exporter` sidecar converts tokens to bytes with a fixed 57344 B/token
  (bf16 KV cache). Here `kv_cache_dtype` is *tuned*: on `fp8*` trials the real figure
  is half that, so the two `*_gb` metrics read **2× too high**. `kv_cache_capacity_tokens`
  / `kv_cache_used_tokens` are exact regardless — compare capacity across trials in
  tokens, not GB. (`7-tensor-parallelism` explicitly assumed `kv_cache_dtype` stays
  unrendered; that assumption does not hold in this study.)
- **Shares every Kubernetes object with `7-tensor-parallelism`** — same namespace
  `llm-serving`, Deployment/Service/ConfigMap `vllm`/`kv-cache-exporter`, Job
  `aiperf-benchmark` in `llm-benchmark`. The two studies **cannot run at the same
  time**; an Akamas `start` on one re-deploys the same objects the other is using.
- **Concurrency ramp calibrated on 1x A10G** (`1-goodput-realistic-load`). At DP=4 the
  1024-concurrency top level is 256 concurrent requests per replica — if no valid
  topology saturates, the goal surface is flat and the optimizer learns little. Check
  the baseline and the first few trials' `num_requests_waiting` before trusting a
  1000-experiment budget.
- **SLA thresholds inherited**, not derived from L4 data (see `goal.constraints`).
- **`preset`-free by design**: TP=3 and TP×DP>4 are excluded up front; any other
  startup failure (e.g. an attention-backend/`kv_cache_dtype` combination not covered by
  the 3 carried constraints) surfaces as a failed experiment — `maxFailedExperiments:
  200` has room, but add a constraint if a pattern repeats.

## Parameters tuned

| Parameter | Domain (⊂ pack 1.7.0) | Baseline |
|---|---|---|
| `vLLM.gpu_memory_utilization` | [0.85, 0.95] | 0.90 (pinned) |
| `vLLM.max_num_seqs` | [16, 1024] | unrendered (vLLM default) |
| `vLLM.max_num_batched_tokens` | [256, 8192] | unrendered |
| `vLLM.kv_cache_dtype` | auto, fp8, fp8_e4m3, fp8_e5m2 | unrendered (auto) |
| `vLLM.performance_mode` | balanced, interactivity, throughput | unrendered |
| `vLLM.optimization_level` | [0, 3] | unrendered |
| `vLLM.enforce_eager` | true, false | unrendered |
| `vLLM.scheduling_policy` | fcfs, priority | unrendered |
| `vLLM.disable_cascade_attn` | true, false | unrendered |
| `vLLM.tokenizer_mode` | auto, hf, slow | unrendered |
| `vLLM.async_scheduling` | true, false | unrendered |
| `vLLM.max_cudagraph_capture_size` | [1, 1024] | unrendered |
| `vLLM.block_size` | 16, 32, 48, 64, 80, 96, 112, 128 | unrendered (16) |
| `vLLM.attention_backend` | FLASH_ATTN, FLASHINFER, TRITON_ATTN | unrendered (auto-select) |
| **`vLLM.tensor_parallel_size`** | **[1, 4]**, ≠ 3, TP×DP ≤ 4 | unrendered (**1**) |
| **`vLLM.data_parallel_size`** | **[1, 4]**, TP×DP ≤ 4 | unrendered (**1**) |

## Prerequisites before this study can be started

- `llm-serving-l4` scaled up with `nvidia.com/gpu: 4` allocatable (true on 2026-09-08).
- vLLM pack **1.7.0** installed (done 2026-09-08 — `akamas describe optimization-pack vLLM`).
- `kv-cache-exporter` ConfigMap, Service port 9400 and ServiceMonitor endpoint applied
  (done 2026-09-08 for `7-tensor-parallelism`; identical manifests here).
- `akamas/id_rsa` present on the `toolbox` host at
  `/work/vllm-benchmark/studies/8-parallelism-tuning/akamas/id_rsa` — **never commit
  it** (`.gitignore` now covers `id_rsa*`, added 2026-09-09).
- No other study running against `llm-serving` (see caveats).

## How to run

```bash
# Akamas resources — all files self-describe kind:/system:, dependency order matters
akamas create -f studies/8-parallelism-tuning/akamas/
akamas describe study "8-Parallelism-Tuning"
akamas start study "8-Parallelism-Tuning"
```

The typed per-resource form is in `akamas/README.md` "Setup & run". **Not yet created
on Akamas** as of 2026-09-09: the `toolbox` CLI session had expired when the create was
attempted (see `akamas/README.md` "Validation performed") — re-login there and run the
commands above; the folder is already in place on the host.

## Results

<Filled in by the study-recap skill once the study finishes.>

## Conclusions

<Filled in by the study-recap skill once the study finishes.>
