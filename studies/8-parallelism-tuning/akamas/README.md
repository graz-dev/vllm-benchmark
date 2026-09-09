# 8-Parallelism-Tuning — Akamas resources

**Created:** 2026-09-09 (system/components/telemetry/workflow copied from
`7-tensor-parallelism`, study manifest modeled on `2-larger-model-g7e`)

Goodput study — maximize `vLLM.prefill_token_throughput + vLLM.decode_token_throughput`
subject to P95 TTFT ≤ 1500 ms / P95 ITL ≤ 300 ms — on 4x NVIDIA L4 (`g6.12xlarge`, node
group `llm-serving-l4`), with the optimizer searching **16 parameters**: the 14 of
`2-larger-model-g7e` plus `vLLM.tensor_parallel_size` and `vLLM.data_parallel_size`
in [1, 4], constrained to `TP × DP ≤ 4` and `TP ≠ 3`. See the study's top-level README
for the design rationale (ROADMAP H5/H6) and caveats.

## Versions

- **vLLM optimization pack**: **1.7.0** — verified installed 2026-09-08
  (`akamas describe optimization-pack vLLM`); every `parametersSelection` domain below
  re-checked 2026-09-09 as a subset of this version's `vLLM` component type.
- **GPU optimization pack**: **1.1.0**; **Kubernetes optimization pack**: **1.8.0-dev**
  (both verified installed 2026-09-08).
- **Target workload**: `vllm/vllm-openai:v0.22.0`, `Qwen/Qwen2.5-7B-Instruct`.
- **Telemetry provider**: Prometheus (`kube-prometheus-stack`), Akamas platform 3.7.1.

## System — `vLLM_Benchmark_8_Parallelism_Tuning`

9 components, identical to `7-tensor-parallelism` except the `system:` field:
- `vLLM` → `vLLM` (`prometheus.{pod,model}: .*`)
- `gpu0`..`gpu3` → `GPU` (`prometheus.pod: .*`, `prometheus.gpu: "0".."3"` — one
  component per physical L4, so every DCGM metric is one series per GPU; DCGM's `gpu`
  label verified as `0`–`3` on this node 2026-09-08)
- `container` → `Kubernetes Container` (`prometheus.pod: ^vllm-.*`)
- `container_loadtest` → `Kubernetes Container` (`prometheus.pod: ^aiperf-benchmark-.*`)
- `cluster` → `Kubernetes Cluster` (`prometheus.node_role: llm-serving-l4`)
- `cluster_loadtest` → `Kubernetes Cluster` (`prometheus.node_role: system-m8a`)

## Telemetry — `Prometheus_8_Parallelism_Tuning`

`telemetry/prometheus.yaml`: 102 metrics, `7-tensor-parallelism`'s catalog (98 + the 4
absolute KV-cache metrics of pack 1.7.0) with **two query fixes applied only in this
study**, both found by running every query against the live Prometheus from the
`toolbox` pod on 2026-09-08 (306 runs: one per component, ×2 window values for the 36
`$DURATION$` queries; 0 queries returned more than one series):

1. `fleet_e2e_latency_percentile`, `fleet_inter_token_latency_percentile`:
   `histogram_quantile(${percentile}, …)` → `histogram_quantile(0.95, …)`. `${…}` is
   Grafana variable syntax, not an Akamas placeholder — Prometheus rejected both with
   `parse error: unexpected character: '$'`, and neither metric appears in the export
   of `1-goodput-realistic-load` (DONE), i.e. they never collected in any study. 0.95
   matches the study's own P95 SLA. The pack's intended semantic for a "percentile"
   metric with no percentile parameter is unclear — raised as a note for the pack owner.
2. The 5 `k8s_cluster_{cpu,memory_pressure_some,memory_pressure_full,io_pressure_some,
   io_pressure_full}` queries: `[$DURATION$]` → `[2m]`. They are the only queries
   reading the `node-exporter` job, scraped every **30 s**; with `config.duration: 30`
   the 30 s window holds one sample and `rate()` returns nothing (measured: empty at
   15/30/45 s, one series from 60 s). `[2m]` ≥ 4× the scrape interval and is independent
   of how `$DURATION$` expands. All other `$DURATION$` queries read 5 s-scraped jobs
   (`vllm`, `dcgm-exporter`) and are unchanged.

Known-empty by nature on this node, not fixed: `gpu_fan_speed` (passively cooled),
`gpu_nvlink_bandwidth_total` (no NVLink), `gpu_fp64_pipe_active` (dcgm-exporter: "metric
not enabled"), `gpu_xid_errors`; and `container_cpu_limit`/`_util`/`_util_max`/
`_throttle_time`/`_throttled_millicores` on `container_loadtest` (`k8s/05-job.yaml` sets
no `limits.cpu` on the AIPerf container — deliberate).

**Caveat inherited from the sidecar**: `kv_cache_capacity_gb`/`kv_cache_used_gb` use a
fixed bf16 bytes-per-token constant; this study tunes `kv_cache_dtype`, so on fp8
trials those two read 2× too high. The `*_tokens` variants are exact.

## Workflow — `8-Parallelism-Tuning-Workflow`

Three tasks, as `7-tensor-parallelism` (paths re-pointed to this study's folder on the
`toolbox` host): `Write config` (FileConfigurator, `ignoreUnsubstitutedTokens: true`,
renders `k8s/01-deployment_template.yaml` → `k8s/01-deployment.yaml`), `Apply config`
(Executor, `k8s/apply_config.sh`, 75 m — strips unrendered `${vLLM.*}` lines, applies,
waits for rollout, dumps all container logs), `RunTest` (Executor,
`k8s/run_test_goodput.sh`, 105 m — deletes and re-creates the AIPerf Job, waits 5700 s,
dumps its logs).

## Study — `8-Parallelism-Tuning`

- **Goal / constraints / windowing**: verbatim from `2-larger-model-g7e`
  (`stability` on `vLLM.prefill_token_throughput`, width 6).
- **`parametersSelection`**: 14 from `2-larger-model-g7e` + `vLLM.tensor_parallel_size`
  [1, 4] + `vLLM.data_parallel_size` [1, 4] (pack: integer, [1, 16] and [1, 8]).
- **`parameterConstraints`**: 3 carried over (FLASH_ATTN ⇒ `kv_cache_dtype == auto`;
  TRITON_ATTN and FLASHINFER ⇒ `kv_cache_dtype != fp8_e5m2`) + 2 new —
  `vLLM.tensor_parallel_size * vLLM.data_parallel_size <= 4` and
  `vLLM.tensor_parallel_size != 3`. 7 valid (TP, DP) pairs out of 16.
- **`baseline`**: `gpu_memory_utilization: 0.90` pinned; the other 15 tuned parameters
  (TP/DP included → vLLM defaults 1/1) and the 10 pinned template tokens in
  `doNotRenderParameters`.
- **`optimize`**: `numberOfExperiments: 1000`, `maxFailedExperiments: 200`.

## Validation performed

- Every `parametersSelection` domain/categories checked against the installed pack
  1.7.0's `component-types/vllm.yaml` (2026-09-09).
- All 102 telemetry queries executed against the live Prometheus (2026-09-08, see
  "Telemetry"); this file differs from the verified `7-tensor-parallelism` copy only in
  the two fixes above.
- **Live `akamas create` NOT yet done.** Attempted 2026-09-09 from the `toolbox` pod
  (files copied to `/work/vllm-benchmark/studies/8-parallelism-tuning/`, `id_rsa` copied
  there from `7-tensor-parallelism` on the host): every call returned *"Access
  forbidden ... requires the 'Administrator' role"* because the pod's CLI session had
  expired (`akamas whoami` → "You need to log into http://kong:8000"). Log in again in
  the pod (`akamas login`) and run "Setup & run" below — the 13 commands are the exact
  ones that failed only on auth. Offline cross-check passed the same day: every
  parameter/metric name resolves to pack 1.7.0's `vLLM` component type, all 16 tuned
  parameters have a `${vLLM.*}` token in the template, goal metrics all present in the
  telemetry instance, all `system:`/`workflow:` references consistent.

## Placeholders / secrets

- **`akamas/id_rsa`** — not in this repo (`.gitignore` covers `id_rsa*`). The workflow
  expects it on the `toolbox` host at
  `/work/vllm-benchmark/studies/8-parallelism-tuning/akamas/id_rsa`; copy it there from
  an existing study's folder **on the host**, never through git.

## Setup & run

Run from the `toolbox` pod (namespace `akamas`, EKS `vllm-bench`), repo checked out at
`/work/vllm-benchmark`. Packs (vLLM 1.7.0, GPU 1.1.0, Kubernetes 1.8.0-dev) and the
`kv-cache-exporter` Kubernetes objects are already in place from `7-tensor-parallelism`.

```bash
S="vLLM_Benchmark_8_Parallelism_Tuning"
D="studies/8-parallelism-tuning/akamas"

akamas create system             $D/system.yaml
akamas create component          $D/components/vllm.yaml               "$S"
akamas create component          $D/components/gpu0.yaml               "$S"
akamas create component          $D/components/gpu1.yaml               "$S"
akamas create component          $D/components/gpu2.yaml               "$S"
akamas create component          $D/components/gpu3.yaml               "$S"
akamas create component          $D/components/container.yaml          "$S"
akamas create component          $D/components/container_loadtest.yaml "$S"
akamas create component          $D/components/cluster.yaml            "$S"
akamas create component          $D/components/cluster_loadtest.yaml   "$S"
akamas create telemetry-instance $D/telemetry/prometheus.yaml          "$S"
akamas create workflow           $D/8-Parallelism-Tuning-Workflow.yaml
akamas create study              $D/8-Parallelism-Tuning.yaml

akamas describe study "8-Parallelism-Tuning"
akamas start study    "8-Parallelism-Tuning"
```

Bulk alternative (every file self-describes `kind:`/`system:`; same dependency order
applies internally): `akamas create -f studies/8-parallelism-tuning/akamas/`.

To tear down (e.g. to recreate after a change to `parametersSelection`/`steps`, which
have no update verb): `akamas delete study "8-Parallelism-Tuning"`, then the workflow,
telemetry instance, components and system in reverse order — or
`akamas delete -f studies/8-parallelism-tuning/akamas/`.
