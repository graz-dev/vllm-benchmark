# 3-Comparison-A10 — Akamas resources

**Created:** 2026-09-02 (scaffolded from `2-larger-model-g7e`)

Optimizes **goodput** — `vLLM.prefill_token_throughput + vLLM.decode_token_throughput`
subject to a P95 TTFT ≤ 1500ms / P95 ITL ≤ 300ms SLA — for `Qwen/Qwen2.5-7B-Instruct`,
served by vLLM on the existing single NVIDIA A10G GPU (`g5.2xlarge`, node group
`llm-serving`, from `0-explorative`/`1-goodput-realistic-load`). Identical
objective/methodology/model/parametersSelection/windowing to `2-larger-model-g7e` —
this study exists purely to re-run that exact config on different hardware for a
direct comparison; see the study's own top-level `README.md`, "Differences from
2-larger-model-g7e", for everything that's actually different (node targeting,
container resources, 2 extra Ampere-specific `parameterConstraints`).

## Versions

- **Optimization pack**: vLLM **1.6.0**
  (`feature/mfu-compute-bandwidth-metrics` branch on top of
  `feature/attention-backend-and-block-size-categorical`, commit `9e177fd` +
  MFU compute/memory-bandwidth metrics — same pack `2-larger-model-g7e` uses).
  **TODO — re-verify before creating these resources on a real instance**: run
  `akamas describe optimization-pack vLLM` first.
- **Target workload**: `Qwen/Qwen2.5-7B-Instruct`, image tag
  **`vllm/vllm-openai:v0.22.0`** — identical to `2-larger-model-g7e` and
  `1-goodput-realistic-load`. Already proven on this exact A10G node group by
  `1-goodput-realistic-load`, so no smoke test needed before trusting an Akamas run.
- **Telemetry provider**: Prometheus (via `kube-prometheus-stack`), same instance/query
  catalog as `1-goodput-realistic-load`/`2-larger-model-g7e` (including the MFU
  compute/memory-bandwidth metrics) — version not independently re-verified here
  either.

## System

- `container` → `Kubernetes Container` (stock type, no properties)
- `gpu` → `GPU` (metrics-only, `prometheus.{pod,gpu}: .*`)
- `vLLM` → `vLLM` (the pack under study, `prometheus.{pod,model}: .*`)

## Telemetry

One Prometheus instance, full metric catalog carried forward unchanged from
`1-goodput-realistic-load` (TTFT/ITL/throughput, saturation signals, KV-cache health,
sequence-length distribution, per-pod fleet metrics, GPU/DCGM metrics) — the study
itself only consumes 4 of these (`prefill_token_throughput`, `decode_token_throughput`,
`time_to_first_token_p95`, `inter_token_latency_p95`) in its goal/constraints; the rest
are recorded for analysis.

## Workflow: `3-Comparison-A10-Workflow`

Three tasks, identical shape to `1-goodput-realistic-load`'s: `Write config`
(FileConfigurator renders `k8s/01-deployment_template.yaml` → `k8s/01-deployment.yaml`),
`Apply config` (Executor runs `k8s/apply_config.sh` — applies the deployment, waits for
rollout, dumps vLLM's own container logs to stdout), `RunTest` (Executor runs
`k8s/run_test_goodput.sh` — applies the AIPerf Job, waits for completion, dumps its logs
to stdout). Both scripts print full workload logs unconditionally (success and failure),
per this plugin's own debuggability convention.

**Same as `1-goodput-realistic-load`'s workflow** (corrected 2026-08-21 — see the
baseline-step note below), `Write config` sets `ignoreUnsubstitutedTokens: true`,
required because the baseline step's `doNotRenderParameters` deliberately leaves most
`${vLLM.*}` tokens unrendered; without the flag `FileConfigurator` would fail on every
baseline trial. `apply_config.sh`'s Step 2 strips those unsubstituted lines before the
file is applied.

## Study: `3-Comparison-A10`

- **Goal**: maximize `vLLM.prefill_token_throughput + vLLM.decode_token_throughput`,
  subject to `vLLM.time_to_first_token_p95 <= 1500` and
  `vLLM.inter_token_latency_p95 <= 300` — identical formula/thresholds to
  `1-goodput-realistic-load` (carried forward as a starting point, not yet recalibrated
  against this study's own data — see the top-level `README.md`).
- **Windowing**: `stability` on `vLLM.prefill_token_throughput` (max), `width: 6` —
  matched to `1-goodput-realistic-load`'s own value, same as `2-larger-model-g7e`.
- **`parametersSelection`**: the same 14 parameters as `1-goodput-realistic-load`/
  `2-larger-model-g7e`, domains/categories unchanged.
- **`parameterConstraints`**: 7 total — see the study README's "Differences from
  2-larger-model-g7e" #3 for the full list and rationale. In short: `FLASH_ATTN`+
  non-`auto` `kv_cache_dtype` and `TRITON_ATTN`/`FLASHINFER`+`fp8_e5m2` are
  hardware-independent vLLM bugs (confirmed via source inspection on
  `2-larger-model-g7e`); `TRITON_ATTN`+`fp8`/`fp8_e4m3` are re-added here because this
  study is back on the exact A10G/Ampere hardware `0-explorative` root-caused them on;
  `FlashInfer`+`block_size` and `max_num_batched_tokens`≥`max_num_seqs` are
  `1-goodput-realistic-load`/`0-explorative`'s own remaining constraints that never
  made it into `2-larger-model-g7e`'s scaffold, re-added here since neither is
  hardware-specific.
- **`vLLM.spec_method`/`vLLM.spec_tokens`** are deliberately absent from both
  `parametersSelection` and the baseline `values` — same treatment as
  `vLLM.prefix_caching_hash_algo`/`vLLM.compilation_mode` — because none of the four are
  referenced by the deployment template at all (speculative decoding pinned off; prefix
  caching hardcoded off; `compilation_mode` has no direct CLI flag).
- **Baseline step**: **corrected 2026-08-21 to match `1-goodput-realistic-load`'s
  design exactly**, after a manual smoke-test deploy against the real
  `vllm/vllm-openai:latest` image crashed with `unrecognized arguments:
  --max-num-partial-prefills=1 --max-long-partial-prefills=1` — those two CLI flags no
  longer exist on this vLLM build. The original design (every referenced parameter
  pinned to an explicit `values` entry, including the pack's own `defaultValue` for
  every non-tuned pinned parameter) rendered those two dead flags onto the command line
  unconditionally, crashing vLLM before it could even start. Now: only
  `gpu_memory_utilization` is pinned via `values` (0.90, since the pack's own
  `defaultValue` of 0.92 doesn't match what this baseline wants); every other
  referenced parameter (13 other tuned + 12 pinned = 25) is excluded via
  `doNotRenderParameters`, leaving its `${vLLM.*}` token unrendered so vLLM applies its
  own real default/CLI behavior instead of a rendered flag — this sidesteps flag-name
  drift entirely, since an excluded parameter's flag is never written at all.
- **Optimize step**: `numberOfExperiments: 1000`, `maxFailedExperiments: 200` — same
  budget as `1-goodput-realistic-load`, as a starting point.

## Validation performed

Structurally validated against a scratch clone of the vLLM pack's actual source
(`feature/attention-backend-and-block-size-categorical`, commit `9e177fd`, matching the
version `1-goodput-realistic-load`'s own README records) before writing these files:
every `parametersSelection`/baseline-`values` parameter name and domain/category is a
confirmed subset of what the pack actually declares; every `goal`/`constraints` metric
token exists both in the pack's declared metrics and in this system's telemetry
instance; every `parameterConstraints` token resolves; component names match the
required `^[a-zA-Z][a-zA-Z0-9_]*$` pattern; `system:` references are consistent across
all files. **Not yet validated against a live Akamas CLI** (unavailable in this
session) — run the commands below against a real instance, and re-confirm the pack
version first (see "Versions" above).

## Placeholders left — fill in before running

- **`akamas/id_rsa`** — deliberately excluded from this scaffold (copying
  `2-larger-model-g7e`'s own committed key here would have duplicated an
  already-known compromised secret into a second location). Supply your own `toolbox`
  host SSH key at this path before the workflow can run.
- **vLLM image tag**: `k8s/01-deployment_template.yaml` pins `vllm/vllm-openai:v0.22.0`
  — identical to `1-goodput-realistic-load`'s own pin, already proven on this exact
  A10G node group.
- **Concurrency sweep** in `k8s/05-job.yaml` — identical to `2-larger-model-g7e`'s
  (150→1024, 12 levels, 300s each), itself carried forward from
  `1-goodput-realistic-load`'s own calibration on this exact A10G hardware — this is
  the *least* likely of the three studies' sweeps to need recalibration, since it was
  originally calibrated here.

## Setup & run

```bash
# Confirm the installed pack version first (see "Versions" above)
akamas describe optimization-pack vLLM

# Typed, per-resource form (dependency order matters)
akamas create system             studies/3-comparison-a10/akamas/system.yaml
akamas create component          studies/3-comparison-a10/akamas/components/container.yaml "vLLM_Benchmark_3_Comparison_A10"
akamas create component          studies/3-comparison-a10/akamas/components/gpu.yaml       "vLLM_Benchmark_3_Comparison_A10"
akamas create component          studies/3-comparison-a10/akamas/components/vllm.yaml      "vLLM_Benchmark_3_Comparison_A10"
akamas create telemetry-instance studies/3-comparison-a10/akamas/telemetry/prometheus.yaml "vLLM_Benchmark_3_Comparison_A10"
akamas create workflow           studies/3-comparison-a10/akamas/3-Comparison-A10-Workflow.yaml
akamas create study              studies/3-comparison-a10/akamas/3-Comparison-A10.yaml

akamas start study "3-Comparison-A10"
```

Or, bulk form (same dependency order still applies internally — every file
self-describes its `kind:`/`system:`):

```bash
akamas create -f studies/3-comparison-a10/akamas/
akamas start study "3-Comparison-A10"
```
