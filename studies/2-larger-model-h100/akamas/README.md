# 2-Larger-Model-H100 — Akamas resources

**Created:** 2026-08-20

Optimizes **goodput** — `vLLM.prefill_token_throughput + vLLM.decode_token_throughput`
subject to a P95 TTFT ≤ 1500ms / P95 ITL ≤ 300ms SLA — for `Qwen/Qwen3.8-27B` (dense,
27.8B parameters) served by vLLM on a single NVIDIA H100 80GB (`p5.4xlarge`). Same
objective and methodology as `1-goodput-realistic-load`, scaled to a ~4x larger model on
faster hardware — see the study's own top-level `README.md` for the full rationale.

## Versions

- **Optimization pack**: vLLM **1.5.1**
  (`feature/attention-backend-and-block-size-categorical` branch, commit `9e177fd` —
  read directly from a scratch clone of
  <https://gitlab.com/akamas/optimization-packs/vllm> while building these resources,
  not assumed). **TODO — re-verify before creating these resources on a real instance**:
  run `akamas describe optimization-pack vLLM` first — if it reports anything other than
  this build, some parameter domains referenced below (in particular `block_size`'s
  ordinal type and `tokenizer_mode`'s categories) may not match what's actually
  installed.
- **Target workload**: `Qwen/Qwen3.8-27B`, image tag **TODO — not yet verified** (see
  study `README.md` "Prerequisites still open" #2 — `v0.22.0` does not support this
  model).
- **Telemetry provider**: Prometheus (via `kube-prometheus-stack`), same instance/query
  catalog as `1-goodput-realistic-load` — version not independently re-verified here
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

## Workflow: `2-Larger-Model-H100-Workflow`

Three tasks, identical shape to `1-goodput-realistic-load`'s: `Write config`
(FileConfigurator renders `k8s/01-deployment_template.yaml` → `k8s/01-deployment.yaml`),
`Apply config` (Executor runs `k8s/apply_config.sh` — applies the deployment, waits for
rollout, dumps vLLM's own container logs to stdout), `RunTest` (Executor runs
`k8s/run_test_goodput.sh` — applies the AIPerf Job, waits for completion, dumps its logs
to stdout). Both scripts print full workload logs unconditionally (success and failure),
per this plugin's own debuggability convention.

**Unlike `1-goodput-realistic-load`'s workflow**, `Write config` does **not** set
`ignoreUnsubstitutedTokens: true` — this study's baseline step (below) pins every
parameter the deployment template references, so no `${vLLM.*}` token is ever left
unsubstituted (that flag was only needed there because that study's baseline
deliberately excluded most parameters from rendering).

## Study: `2-Larger-Model-H100`

- **Goal**: maximize `vLLM.prefill_token_throughput + vLLM.decode_token_throughput`,
  subject to `vLLM.time_to_first_token_p95 <= 1500` and
  `vLLM.inter_token_latency_p95 <= 300` — identical formula/thresholds to
  `1-goodput-realistic-load` (carried forward as a starting point, not yet recalibrated
  against this study's own data — see the top-level `README.md`).
- **Windowing**: `stability` on `vLLM.prefill_token_throughput` (max), `width: 12` —
  matched to the carried-forward 12-level concurrency sweep in `k8s/05-job.yaml`.
- **`parametersSelection`**: the same 14 parameters as `1-goodput-realistic-load`,
  domains/categories unchanged (all confirmed subsets of the pack's own declared
  domains — see "Validation" below).
- **`parameterConstraints`**: the same 6 as `1-goodput-realistic-load`. The 3
  `TRITON_ATTN`+fp8 exclusions are carried forward as a safe default but **flagged as an
  open TODO** in the study YAML itself — they were root-caused as Ampere (A10G)-specific
  and have not been re-tested on Hopper (H100), which has native FP8 Tensor Core
  support.
- **`vLLM.spec_method`/`vLLM.spec_tokens`** are deliberately absent from both
  `parametersSelection` and the baseline `values` — same treatment as
  `vLLM.prefix_caching_hash_algo`/`vLLM.compilation_mode` — because none of the four are
  referenced by the deployment template at all (speculative decoding pinned off; prefix
  caching hardcoded off; `compilation_mode` has no direct CLI flag).
- **Baseline step**: a **simpler design than `1-goodput-realistic-load`'s** — every
  referenced parameter (14 tuned + 11 pinned = 25) gets an explicit value in `values`
  directly (the 14 tuned ones at the vLLM pack's own `defaultValue`, except
  `gpu_memory_utilization` pinned to 0.90), rather than that study's elaborate
  29-parameter `doNotRenderParameters` exclusion list. No `renderParameters`/
  `doNotRenderParameters` needed here.
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

- **`akamas/id_rsa`** — does not exist yet. This study's workflow (`toolbox` host SSH
  key) references `/work/vllm-benchmark/studies/2-larger-model-h100/akamas/id_rsa` at
  the exact same path convention as `0-explorative`/`1-goodput-realistic-load`, but no
  key has been generated or copied here — this file must exist on the actual `toolbox`
  host at that path (and, per this repo's existing convention, likely also committed
  here — see `.gitignore`'s `id_rsa`/`id_rsa.*` rules, which only block *new* untracked
  files, not resources you deliberately add) before the workflow can run.
- **vLLM image tag** in `k8s/01-deployment_template.yaml` (`vllm/vllm-openai:latest`) —
  a functional placeholder, not a pinned, verified tag. Replace once confirmed (see
  study `README.md` "Prerequisites still open" #2).
- **Concurrency sweep** in `k8s/05-job.yaml` — carried forward from
  `1-goodput-realistic-load`, not yet recalibrated for this model/hardware (see study
  `README.md` "Prerequisites still open" #3).

## Setup & run

```bash
# Confirm the installed pack version first (see "Versions" above)
akamas describe optimization-pack vLLM

# Typed, per-resource form (dependency order matters)
akamas create system             studies/2-larger-model-h100/akamas/system.yaml
akamas create component          studies/2-larger-model-h100/akamas/components/container.yaml "vLLM_Benchmark_2_Larger_Model_H100"
akamas create component          studies/2-larger-model-h100/akamas/components/gpu.yaml       "vLLM_Benchmark_2_Larger_Model_H100"
akamas create component          studies/2-larger-model-h100/akamas/components/vllm.yaml      "vLLM_Benchmark_2_Larger_Model_H100"
akamas create telemetry-instance studies/2-larger-model-h100/akamas/telemetry/prometheus.yaml "vLLM_Benchmark_2_Larger_Model_H100"
akamas create workflow           studies/2-larger-model-h100/akamas/2-Larger-Model-H100-Workflow.yaml
akamas create study              studies/2-larger-model-h100/akamas/2-Larger-Model-H100.yaml

akamas start study "2-Larger-Model-H100"
```

Or, bulk form (same dependency order still applies internally — every file
self-describes its `kind:`/`system:`):

```bash
akamas create -f studies/2-larger-model-h100/akamas/
akamas start study "2-Larger-Model-H100"
```
