# 2-Larger-Model-G7e — Akamas resources

**Created:** 2026-08-20

Optimizes **goodput** — `vLLM.prefill_token_throughput + vLLM.decode_token_throughput`
subject to a P95 TTFT ≤ 1500ms / P95 ITL ≤ 300ms SLA — for `Qwen/Qwen3.8-27B` (dense,
27.8B parameters) served by vLLM on a single NVIDIA RTX PRO 6000 Blackwell 96GB
(`g7e.4xlarge` — swapped 2026-08-21 from H100 80GB/`p5.4xlarge`, no regional capacity;
see study `README.md`). Same objective and methodology as `1-goodput-realistic-load`,
scaled to a ~4x larger model on different, higher-VRAM/lower-bandwidth single-GPU
hardware — see the study's own top-level `README.md` for the full rationale.

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
- **Target workload**: `Qwen/Qwen3.8-27B`, image tag **`vllm/vllm-openai:v0.27.1`
  (resolved 2026-08-21 via a real manual deploy, see study `README.md` "Prerequisites
  still open" #2 — `v0.22.0` does not support this model)**. Still open: whether the
  vLLM optimization pack's parameter set (built against `0.22.0`) still applies
  cleanly to `0.27.1`.
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

## Workflow: `2-Larger-Model-G7e-Workflow`

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

## Study: `2-Larger-Model-G7e`

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
  and have not been re-tested on this study's actual hardware, RTX PRO 6000 Blackwell
  (SM120) — a third, distinct architecture from both A10G and H100/Hopper (see the
  hardware-swap note above); do not assume Hopper's "native FP8, exclusion unneeded"
  reasoning transfers here either — SM120's own FP8/FP4 kernel-selection support has
  documented rough edges upstream.
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

- **`akamas/id_rsa`** — does not exist yet. This study's workflow (`toolbox` host SSH
  key) references `/work/vllm-benchmark/studies/2-larger-model-g7e/akamas/id_rsa` at
  the exact same path convention as `0-explorative`/`1-goodput-realistic-load`, but no
  key has been generated or copied here — this file must exist on the actual `toolbox`
  host at that path (and, per this repo's existing convention, likely also committed
  here — see `.gitignore`'s `id_rsa`/`id_rsa.*` rules, which only block *new* untracked
  files, not resources you deliberately add) before the workflow can run.
- ~~**vLLM image tag**~~ **RESOLVED 2026-08-21** — `k8s/01-deployment_template.yaml`
  now pins `vllm/vllm-openai:v0.27.1` (verified via a real manual deploy, see study
  `README.md` "Prerequisites still open" #2), no longer floating on `:latest`.
- **Concurrency sweep** in `k8s/05-job.yaml` — carried forward from
  `1-goodput-realistic-load`, not yet recalibrated for this model/hardware (see study
  `README.md` "Prerequisites still open" #3).

## Setup & run

```bash
# Confirm the installed pack version first (see "Versions" above)
akamas describe optimization-pack vLLM

# Typed, per-resource form (dependency order matters)
akamas create system             studies/2-larger-model-g7e/akamas/system.yaml
akamas create component          studies/2-larger-model-g7e/akamas/components/container.yaml "vLLM_Benchmark_2_Larger_Model_G7e"
akamas create component          studies/2-larger-model-g7e/akamas/components/gpu.yaml       "vLLM_Benchmark_2_Larger_Model_G7e"
akamas create component          studies/2-larger-model-g7e/akamas/components/vllm.yaml      "vLLM_Benchmark_2_Larger_Model_G7e"
akamas create telemetry-instance studies/2-larger-model-g7e/akamas/telemetry/prometheus.yaml "vLLM_Benchmark_2_Larger_Model_G7e"
akamas create workflow           studies/2-larger-model-g7e/akamas/2-Larger-Model-G7e-Workflow.yaml
akamas create study              studies/2-larger-model-g7e/akamas/2-Larger-Model-G7e.yaml

akamas start study "2-Larger-Model-G7e"
```

Or, bulk form (same dependency order still applies internally — every file
self-describes its `kind:`/`system:`):

```bash
akamas create -f studies/2-larger-model-g7e/akamas/
akamas start study "2-Larger-Model-G7e"
```
