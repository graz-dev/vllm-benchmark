# 4-Goodput-Extended — Akamas resources

**Created:** 2026-09-04 (scaffolded from `2-larger-model-g7e`)

**Not an optimization study** — verifies **goodput** —
`vLLM.prefill_token_throughput + vLLM.decode_token_throughput` subject to a P95
TTFT ≤ 1500ms / P95 ITL ≤ 300ms SLA — reproduces `2-larger-model-g7e`'s own
best-found trial (experiment 28) exactly via a `baseline` step, then tests raising
`max_num_seqs` further via a `preset` step, for `Qwen/Qwen2.5-7B-Instruct` served by
vLLM on the same single NVIDIA RTX PRO 6000 Blackwell 96GB (`g7e.4xlarge`,
`llm-serving-g7e`) node group `2-larger-model-g7e` uses. See the study's own top-level
`README.md` for the full rationale.

## Versions

- **Optimization pack**: vLLM **1.6.0** (same as `2-larger-model-g7e`'s final state —
  `feature/mfu-compute-bandwidth-metrics` on top of
  `feature/attention-backend-and-block-size-categorical`, commit `9e177fd`).
  **TODO — re-verify before creating these resources on a real instance**: run
  `akamas describe optimization-pack vLLM` first.
- **Target workload**: `Qwen/Qwen2.5-7B-Instruct`, image tag
  **`vllm/vllm-openai:v0.22.0`** — identical to `2-larger-model-g7e`'s final config,
  already smoke-tested and confirmed healthy on this exact g7e node group.
- **Telemetry provider**: Prometheus (via `kube-prometheus-stack`), same instance/query
  catalog as `2-larger-model-g7e` (including the MFU compute/memory-bandwidth
  metrics).

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

## Workflow: `4-Goodput-Extended-Workflow`

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

## Study: `4-Goodput-Extended`

- **Goal**: maximize `vLLM.prefill_token_throughput + vLLM.decode_token_throughput`,
  subject to `vLLM.time_to_first_token_p95 <= 1500` and
  `vLLM.inter_token_latency_p95 <= 300` — identical to `2-larger-model-g7e`.
- **Windowing**: `stability` on `vLLM.prefill_token_throughput` (max), `width: 6` —
  identical to `2-larger-model-g7e`, kept so scores are directly comparable.
- **No `parametersSelection` / `parameterConstraints`** — this study runs exactly 2
  fixed-configuration trials, nothing to search. See the study README's "Differences
  from 2-larger-model-g7e" #2 for why (also: `max_num_seqs=2048` in the `preset` step
  is outside that study's own domain for the parameter, so omitting
  `parametersSelection` avoids a domain conflict).
- **Baseline step**: pins experiment 28's exact winning config from
  `2-larger-model-g7e`'s optimize step — all 14 tuned parameters from that
  experiment's own CSV row, rendered via `values:`, no `doNotRenderParameters`. The 12
  "Pinned" parameters from `2-larger-model-g7e`'s own README table are **not
  referenced at all** here — no `${vLLM.*}` token for them in
  `k8s/01-deployment_template.yaml`, so vLLM applies its own real defaults
  unconditionally (see the study README's "Differences" #3 for the full reasoning).
- **Preset step**: identical to baseline except `max_num_seqs: 2048` instead of 1020.
- **No optimize step.**

## Validation performed

Every `baseline`/`preset` `values:` parameter name is a confirmed subset of what the
pack actually declares (the same 14 tuned parameters `2-larger-model-g7e` already
references);
every `goal`/`constraints` metric token exists both in the pack's declared metrics and
in this system's telemetry instance; component names match the required
`^[a-zA-Z][a-zA-Z0-9_]*$` pattern; `system:` references are consistent across all
files. **Not independently re-validated against a live Akamas CLI for this specific
study** (in particular, whether `max_num_seqs=2048` in the `preset` step is accepted
given the pack's own domain for that parameter caps it at 1024 — untested) — run the
commands below against a real instance, and re-confirm the pack version first (see
"Versions" above).

## Placeholders left — fill in before running

- **`akamas/id_rsa`** — does not exist yet. This study's workflow (`toolbox` host SSH
  key) references `/work/vllm-benchmark/studies/4-goodput-extended/akamas/id_rsa` at
  deliberately excluded from this scaffold (copying `2-larger-model-g7e`'s own
  committed key here would have duplicated an already-known compromised secret into a
  second location) — supply your own `toolbox` host SSH key at this path before the
  workflow can run.
- **vLLM image tag**: `k8s/01-deployment_template.yaml` pins `vllm/vllm-openai:v0.22.0`
  — identical to `2-larger-model-g7e`'s final config, already proven on this exact
  g7e node group.
- **Concurrency sweep** in `k8s/05-job.yaml` — extended to 24 levels (150→2048, see
  study README "Differences from 2-larger-model-g7e" #4) — not independently
  re-verified against a live cluster yet, just computed geometrically.

## Setup & run

```bash
# Confirm the installed pack version first (see "Versions" above)
akamas describe optimization-pack vLLM

# Typed, per-resource form (dependency order matters)
akamas create system             studies/4-goodput-extended/akamas/system.yaml
akamas create component          studies/4-goodput-extended/akamas/components/container.yaml "vLLM_Benchmark_4_Goodput_Extended"
akamas create component          studies/4-goodput-extended/akamas/components/gpu.yaml       "vLLM_Benchmark_4_Goodput_Extended"
akamas create component          studies/4-goodput-extended/akamas/components/vllm.yaml      "vLLM_Benchmark_4_Goodput_Extended"
akamas create telemetry-instance studies/4-goodput-extended/akamas/telemetry/prometheus.yaml "vLLM_Benchmark_4_Goodput_Extended"
akamas create workflow           studies/4-goodput-extended/akamas/4-Goodput-Extended-Workflow.yaml
akamas create study              studies/4-goodput-extended/akamas/4-Goodput-Extended.yaml

akamas start study "4-Goodput-Extended"
```

Or, bulk form (same dependency order still applies internally — every file
self-describes its `kind:`/`system:`):

```bash
akamas create -f studies/4-goodput-extended/akamas/
akamas start study "4-Goodput-Extended"
```
