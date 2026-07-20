# 1-Goodput-Realistic-Load

**Status:** TODO
**Dates:** —

## Objective

Maximize **goodput** — `vLLM.prefill_token_throughput + vLLM.decode_token_throughput`
subject to a P95 TTFT and P95 ITL latency SLA (`goal.constraints`) — rather than
`0-explorative`'s throughput-only goal. This is the preliminary step of `ROADMAP.md`
Section D's plan: validate a realistic load-testing tool and the vLLM pack's newest
parameters (context parallelism, speculative decoding) on the *same known-good A10G
hardware* as `0-explorative`, before Section D's later studies also change hardware
(H100 + DRA). Deliberately keeps the hardware/model/vLLM version constant so any
difference observed is attributable to the tooling/parameter changes below, not a
hardware confound.

Three deliberate changes from `0-explorative`, all in service of the same goal
(a more realistic, latency-aware measurement of this hardware's actual ceiling):

1. **Load generator**: NVIDIA AIPerf (`ai-dynamo/aiperf`) — replacing GuideLLM's
   synthetic fixed `prompt_tokens=512,output_tokens=128` shape with real ShareGPT
   replay (multi-turn conversations, natural variable lengths). Originally built on
   `kubernetes-sigs/inference-perf`, swapped for AIPerf 2026-07-17 — see "Load
   generator" below and "Incidents found during the optimize step" for why.
2. **Load pattern**: a **concurrency sweep** (7 levels, 1→64, closed-loop) toward this
   server's own saturation point, not a single fixed-rate throughput-seeking
   benchmark — this directly surfaces *where* the latency SLA starts being violated,
   which is exactly the goodput ceiling this study is trying to find.
3. **Parameter surface**: `0-explorative`'s 16 tuned parameters minus `dtype` and
   `prefix_caching_hash_algo` (14 total — see "Parameters tuned" below). Pack v1.5.1's
   new `spec_method`/`spec_tokens` (speculative decoding) were tried and then dropped
   entirely 2026-07-17 after 5 distinct crashes across the `optimize` step — see
   "Incidents found during the optimize step."

## Stack & versions

- **Akamas version:** 3.7.x
- **Optimization pack(s) used:** vLLM **1.5.1**
  (https://gitlab.com/akamas/optimization-packs/vllm, branch
  `feature/attention-backend-and-block-size-categorical` — **not yet merged/tagged,
  see `ROADMAP.md`'s URGENT debt item**: confirm with `akamas describe
  optimization-pack vLLM` that the installed pack actually reports `1.5.1` before
  creating this study's components, since the installation could still be on the
  old, broken `1.2.0`). GPU pack: metrics-only, same as `0-explorative` — not
  independently re-verified for this study either. Kubernetes pack: stock
  `Kubernetes Container` component type, no properties needed.
- **Workload under test:** `vllm/vllm-openai:v0.22.0` serving `Qwen/Qwen2.5-7B-Instruct`
  (served as `qwen2.5-7b`), namespace `llm-serving` — identical to `0-explorative`.
- **Cluster / hardware:** single NVIDIA A10G GPU — **the same EKS cluster
  (`vllm-bench`, `us-east-2`) as `0-explorative`, deliberately reused** (see
  `infra/README.md`). This study still has its own full `infra/` copy per this repo's
  atomic-per-study convention, but `infra/eks/provision.sh` will detect the cluster
  already exists and skip creation.
- **Load generator:** NVIDIA AIPerf (`ai-dynamo/aiperf`, PyPI `aiperf==0.11.0` — no
  official container image found, installed via `pip` into a plain `python:3.12-slim`
  base at container start, see `k8s/05-job.yaml`), `--public-dataset sharegpt`
  (AIPerf downloads/caches ShareGPT from HuggingFace itself, real variable-length
  prompts and outputs — no custom dataset-prep pipeline needed, unlike the tool it
  replaces), `--tokenizer Qwen/Qwen2.5-7B-Instruct` (required explicitly — `--model`
  is the *served* name `qwen2.5-7b`, which isn't a valid HF repo id for tokenizer
  lookup; same class of issue the old load generator had), `--concurrency
  1,2,4,8,16,32,64` (closed-loop sweep, 60s per level via `--benchmark-duration 60`),
  `--goodput "time_to_first_token:1500 inter_token_latency:300"` (mirrors
  `goal.constraints` in the tool's own report). See "Load generator" below for the
  full sizing rationale and why this replaced `kubernetes-sigs/inference-perf`.
- **Telemetry:** Prometheus (same instance/metric catalog as `0-explorative` —
  `kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`,
  `duration: 30`, `logLevel: DETAILED`). Unaffected by the load-generator swap —
  Akamas reads vLLM's own `/metrics` directly, not the load generator's own report
  files, regardless of which tool is driving traffic.

## Parameters tuned

14 of the pack's 30 parameters are searched (0-explorative's original 16, minus
`dtype` and `prefix_caching_hash_algo`, both removed 2026-07-17 — see below); 12 are
pinned (single GPU, non-MoE model, or a real incident already root-caused on this
exact hardware/vLLM version — see `0-explorative`'s own README for the incident
write-ups, unchanged here since it's the same stack); 4 are deliberately excluded
(`compilation_mode`, plus `spec_method`/`spec_tokens`/`prefix_caching_hash_algo`,
all removed 2026-07-17 — see below and "Incidents found during the optimize step").

| Parameter | Domain / categories | Baseline |
|---|---|---|
| `vLLM.gpu_memory_utilization` | [0.85, 0.95] | **0.90** (explicitly rendered — see "Baseline rendering" below) |
| `vLLM.max_num_seqs` | [16, 1024] | *(not rendered)* |
| `vLLM.max_num_batched_tokens` | [256, 8192] | *(not rendered)* |
| `vLLM.kv_cache_dtype` | auto, fp8, fp8_e4m3, fp8_e5m2 | *(not rendered)* |
| `vLLM.performance_mode` | balanced, interactivity, throughput | *(not rendered)* |
| `vLLM.optimization_level` | [0, 3] | *(not rendered)* |
| `vLLM.enforce_eager` | true, false | *(not rendered)* |
| `vLLM.scheduling_policy` | fcfs, priority | *(not rendered)* |
| `vLLM.disable_cascade_attn` | true, false | *(not rendered)* |
| `vLLM.tokenizer_mode` | auto, hf, slow | *(not rendered)* |
| `vLLM.async_scheduling` | true, false | *(not rendered)* |
| `vLLM.max_cudagraph_capture_size` | [1, 1024] | *(not rendered)* |
| `vLLM.block_size` | 16, 32, 48, 64, 80, 96, 112, 128 (**ordinal**, not categorical — pack v1.5.1) | *(not rendered)* |
| `vLLM.attention_backend` | FLASH_ATTN, FLASHINFER, TRITON_ATTN | *(not rendered)* |

**Removed from tuning 2026-07-17**: `vLLM.dtype` (moved to Pinned — it's the model's
numeric precision/quantization, not a goodput lever this study cares about) and
`vLLM.prefix_caching_hash_algo` (moved to Excluded — prefix caching is now disabled
entirely via a hardcoded `--no-enable-prefix-caching` flag, so which hash algorithm
it would have used no longer applies). `vLLM.spec_method`/`vLLM.spec_tokens` (the
pack v1.5.1 speculative-decoding parameters, genuinely explored for the first time
in this study) were also removed entirely — see "Incidents found during the optimize
step" for the 5 distinct crashes that motivated dropping them rather than continuing
to patch around each one.

### Considered for tuning and rejected (2026-07-17): partial-prefill params, `num_gpu_blocks_override`

Checked whether `max_num_partial_prefills`, `max_long_partial_prefills`,
`long_prefill_token_threshold`, and `num_gpu_blocks_override` should move from
pinned/absent into `parametersSelection`. Decision: no change, all stay as they are.

- The first three already exist in the pack and are already pinned here — see the
  Pinned table below — because of a **100%-reproducible crash** on this exact
  vLLM 0.22.0/A10G combo whenever `max_num_partial_prefills > 1`
  (`NotImplementedError: Concurrent Partial Prefill is not supported`, see
  `0-explorative`'s "Incident: Concurrent Partial Prefill crash"). Tuning it would
  fail nearly every experiment; the other two are inert whenever
  `max_num_partial_prefills` stays at 1, so tuning them alone would spend budget on
  parameters with no measurable effect. Confirmed the incident's root cause is still
  current (same vLLM version, not upgraded — see "vLLM version" discussion) before
  deciding to leave all three untouched.
- `num_gpu_blocks_override` does **not** exist in the pack. Confirmed against vLLM
  0.22.0 source (`vllm/config/cache.py`): `int | None = None`, docstring "Used for
  testing preemption" — not a production sizing knob. When set, it **replaces** the
  `gpu_memory_utilization`-derived KV-cache block count outright, with no validation
  against actual free VRAM (`vllm/v1/core/kv_cache_utils.py`'s
  `get_kv_cache_configs`), and `block_size` is a direct multiplier on the memory
  footprint per block — real OOM risk if the optimizer picks a value that doesn't
  fit, compounded by `block_size` already being tuned here. Decided not to add it to
  the pack or this study — out of scope for a goodput-tuning study, not a testing/
  preemption study.

### Baseline rendering — a deliberate change from `0-explorative`

`0-explorative`'s baseline `values:` explicitly restated vLLM's own assumed defaults
for every tuned parameter. This study's baseline instead renders **only**
`vLLM.gpu_memory_utilization`, pinned to **0.90**; all other 29 pack parameters
(13 other tuned params, 12 pinned params, and 4 excluded params) are excluded from
computation, so the rendered command ends up close to a genuinely
bare `vllm serve <model> --port=8000 --host=0.0.0.0 --served-model-name=...
--enable-mfu-metrics --gpu-memory-utilization=0.90`, not every tunable flag re-stated
at a default value. The `optimize` step sets neither of these fields, so Akamas stays
fully free to pick any `parametersSelection` value there — this restriction is
baseline-only.

This is a deliberate 2026-07-15/16 design, arrived at over three corrections:

1. `renderParameters`/`doNotRenderParameters` were initially assumed to omit CLI flags
   from the rendered template directly — confirmed against Akamas' own live docs that
   they only control which parameters Akamas *computes a value for*, not the
   template's own text.
2. The first implementation of "render only gpu_memory_utilization" used
   `doNotRenderParameters: ["vLLM.*"]` with `renderParameters:
   ["vLLM.gpu_memory_utilization"]` as an override on the same wildcard. Asked the live
   docs directly whether `renderParameters` can carve an exception out of an
   overlapping `doNotRenderParameters` wildcard on the same component prefix — answer:
   **undocumented, no stated precedence**, and the docs' own guidance is to avoid the
   overlap rather than rely on undefined behavior. Fixed by dropping
   `renderParameters` entirely and enumerating `doNotRenderParameters` explicitly as
   every pack parameter *except* `gpu_memory_utilization` (29 names, no wildcard) — see
   `akamas/1-Goodput-Realistic-Load.yaml`'s baseline step for the full list.
3. **Corrected 2026-07-16 from an actual baseline rollout**: an excluded parameter's
   `${vLLM.*}` token does **not** get left as literal unsubstituted text as originally
   assumed — Akamas substitutes it with an **empty string** instead
   (`- "--max-num-seqs=${vLLM.max_num_seqs}"` renders to `- "--max-num-seqs="`). Left
   as-is, this crashes vLLM at startup — argparse rejects an empty value for any
   int/float/enum flag. `apply_config.sh`'s Step 2 now strips these empty-value flag
   lines (not just literal-unsubstituted-token lines, which it was originally written
   to catch and which apparently never actually occurs) before the file is applied —
   only after that strip does vLLM genuinely fall back to its own real startup
   defaults for every excluded parameter.

Two things worth spelling out about the resulting split:

- **Why `gpu_memory_utilization` needs an explicit `values:` pin and can't just be left
  un-excluded at its pack default**: the pack's own `defaultValue` for it is **0.92**
  (matching vLLM's real engine default), not the 0.90 this baseline is meant to
  represent — so it must be pinned explicitly, not merely "not excluded."
  `max_num_seqs`, by contrast, has no single fixed vLLM default (the pack notes it's
  GPU/mode dependent, ranging 128-1024) and vLLM never requires the flag to start at
  all — so it's simply excluded like everything else, left to vLLM's own
  auto-derivation rather than pinned to an arbitrary Akamas-side number.
- **Why this doesn't reintroduce the `attention_backend` auto-selection crash risk**
  flagged earlier in this study's design: that `0-explorative` crash came from
  auto-selection interacting with *other* non-default tuned values (a specific
  dtype/kv_cache_dtype/block_size combination). Here, every parameter other than
  `gpu_memory_utilization` is simultaneously at vLLM's own stock default — i.e. exactly
  vLLM's standard, most-tested startup path, not an odd Akamas-picked combination.

The actual mechanism combines three pieces:

1. `values: {vLLM.gpu_memory_utilization: 0.90}` + an explicit 29-name
   `doNotRenderParameters` list (everything except `gpu_memory_utilization`) on the
   baseline step (`akamas/1-Goodput-Realistic-Load.yaml`).
2. `ignoreUnsubstitutedTokens: true` on the workflow's FileConfigurator task
   (`akamas/1-Goodput-Realistic-Load-Workflow.yaml`) — without this, FileConfigurator
   would fail outright rather than render the excluded parameters' tokens as empty.
3. `apply_config.sh`'s Step 2 (`k8s/apply_config.sh`) strips any line whose flag was
   rendered with an empty value (`- "--flag="`), plus any line still containing a
   literal unsubstituted `${vLLM.` token as defense-in-depth — a generic rule that does
   nothing on optimize-step trials, where every token gets a real, non-empty computed
   value.

Pinned (not in `parametersSelection`, unchanged from `0-explorative` — same hardware,
same vLLM version, same incidents apply):

| Parameter | Value | Why |
|---|---|---|
| `vLLM.tensor_parallel_size` | 1 | Only one GPU available. |
| `vLLM.pipeline_parallel_size` | 1 | Only one GPU available. |
| `vLLM.data_parallel_size` | 1 | Only one GPU available. |
| `vLLM.enable_expert_parallel` | false | Qwen2.5-7B is dense, not MoE; irrelevant. |
| `vLLM.disable_custom_all_reduce` | false (pack default) | Only relevant when `tensor_parallel_size > 1`; a no-op at TP=1. |
| `vLLM.decode_context_parallel_size` **(NEW)** | 1 | Context parallelism needs multiple GPUs, same reasoning as `tensor_parallel_size`. See the pack's own `parameterConstraints` doc for the divisibility constraint this would need if ever un-pinned. |
| `vLLM.prefill_context_parallel_size` **(NEW)** | 1 | Same reasoning. |
| `vLLM.max_model_len` | 32768 | `0-explorative` A/B-tested this live and found no measurable effect on available KV cache memory for this model/config — see that study's own README for the full finding. |
| `vLLM.max_num_partial_prefills` | 1 | "Concurrent Partial Prefill" is not supported on this vLLM 0.22.0/A10G combo — see `0-explorative`'s "Incident: Concurrent Partial Prefill crash." |
| `vLLM.max_long_partial_prefills` | 1 | Same incident. |
| `vLLM.long_prefill_token_threshold` | 0 | Same incident. |
| `vLLM.dtype` **(moved here 2026-07-17)** | auto (pack default) | Model numeric precision/quantization — not a goodput lever this study is investigating; left at vLLM's own auto-selection from the checkpoint. |

**Excluded entirely** (not in `parametersSelection`, not pinned):

| Parameter | Why |
|---|---|
| `vLLM.compilation_mode` | Same reasoning as `0-explorative` — no direct top-level CLI flag exists for it (only reachable via the nested `--compilation-config` JSON argument). |
| `vLLM.prefix_caching_hash_algo` **(moved here 2026-07-17)** | Prefix caching is now disabled entirely via a hardcoded `--no-enable-prefix-caching` flag in the deployment template (confirmed against vLLM v0.22.0 source: `enable_prefix_caching: bool = True` in `config/cache.py`, a standard `BooleanOptionalAction` flag) — which hash algorithm it would have used no longer applies. |
| `vLLM.spec_method` / `vLLM.spec_tokens` **(removed 2026-07-17)** | Speculative decoding caused 5 distinct crashes across the `optimize` step (KV cache budget exhaustion, `mtp` not implemented, `suffix` missing a dependency, `ngram_gpu`+`optimization_level=0`, `ngram`+`async_scheduling=true`) — see "Incidents found during the optimize step" below. Rather than keep patching around each new interaction, both parameters and the deployment template's `--spec-method`/`--spec-tokens` flags were removed entirely; vLLM now runs with speculative decoding off, unconditionally. |

## Parameter constraints

All 6 carried forward unchanged from `0-explorative` (the `block_size` ones are
unaffected by its categorical→ordinal type change). The 4 speculative-decoding
constraints added while `spec_method`/`spec_tokens` were still tuned (2 sentinel-gate
ones + the `ngram_gpu`/`optimization_level` and `ngram`/`async_scheduling`
interaction fixes) were **removed 2026-07-17** along with those two parameters
themselves — there's nothing left to constrain once neither is in
`parametersSelection`. Full history of what each one guarded against is kept in
"Incidents found during the optimize step" below, not deleted outright.

```yaml
parameterConstraints:
  - name: FLASH_ATTN only supports auto kv_cache_dtype
    formula: vLLM.attention_backend != "FLASH_ATTN" || vLLM.kv_cache_dtype == "auto"
  - name: FlashInfer only supports block_size 16, 32, or 64
    formula: vLLM.attention_backend != "FLASHINFER" || vLLM.block_size == "16" || vLLM.block_size == "32" || vLLM.block_size == "64"
  - name: max_num_batched_tokens must be at least max_num_seqs
    formula: vLLM.max_num_batched_tokens >= vLLM.max_num_seqs
  - name: TRITON_ATTN does not support fp8 kv_cache_dtype on Ampere
    formula: vLLM.attention_backend != "TRITON_ATTN" || vLLM.kv_cache_dtype != "fp8"
  - name: TRITON_ATTN does not support fp8_e4m3 kv_cache_dtype on Ampere
    formula: vLLM.attention_backend != "TRITON_ATTN" || vLLM.kv_cache_dtype != "fp8_e4m3"
  - name: TRITON_ATTN does not support fp8_e5m2 kv_cache_dtype (query-quant bug)
    formula: vLLM.attention_backend != "TRITON_ATTN" || vLLM.kv_cache_dtype != "fp8_e5m2"
```

Re-verified 2026-07-15 whether the `TRITON_ATTN`+fp8 exclusions are still needed on
this hardware: **not re-tested** — this study reuses the identical A10G/vLLM 0.22.0
combo `0-explorative` found these crashes on, so the same exclusions are kept rather
than assumed fixed. (They would only plausibly become unnecessary on Hopper+ hardware,
per that incident's own root cause — not relevant here.)

## Windowing — `stability`, not `trim`

`0-explorative`'s single fixed-rate load converges to one steady state, so a `trim`
window (cut a fixed amount off the head/tail) had an obvious, principled cut point.
This study's load is a **sweep** (7 concurrency levels, 1→64, closed-loop — see
"Load generator" below) — there is no single steady state to trim around, so
`windowing.type: stability` is used instead: scan for a temporally stable interval,
then, among the stable candidates, pick the one where a chosen metric is maximized.

```yaml
windowing:
  type: stability
  stability:
    metric: vLLM.prefill_token_throughput
    width: 7
    maxStdDev: 300000000
    when:
      metric: vLLM.prefill_token_throughput
      is: max
```

`when` nests **inside** `stability`, not as a sibling under `windowing` — an early draft
had it as a sibling (and also carried a `task: RunTest` key) and failed `akamas create
study` outright: `$.stability.when: is missing but it is required` /
`$.task`/`$.when: is not defined in the schema`. Confirmed against both the live docs
and the real error: `task` is a `trim`-only key (it tells trim which workflow task's
time range to anchor `trim[0]` on) — `stability` has no `task` key at all, since it
scans the trial's own timeseries directly. In practice this still lands within the
`RunTest` task's window regardless, since `vLLM.prefill_token_throughput` only has real
values while vLLM is actually serving load, not during the deploy tasks.

- **Same metric for both roles** (`prefill_token_throughput` for both the stability
  check and the `when: max` comparison) — a single-metric pattern, not the
  two-metric split (a separate "has it settled" indicator plus a separate "which one is
  best" comparison) considered earlier. `when: max` naturally favors the highest-
  throughput stable interval, which for a monotonic load sweep lands near the
  highest-load level the server sustains without degrading — i.e. "toward the top of
  the sweep" without hardcoding that assumption, and without penalizing an earlier
  degradation if one occurs.
- **`width: 7`** samples, native/raw resolution (no explicit `resolution` set) —
  matches the 7 concurrency levels in the AIPerf sweep, one sample per level (bumped
  from 6 to 7 on 2026-07-17 when the load generator switched from a 6-stage rate
  ramp to a 7-level concurrency sweep — see "Load generator" below).
- **`maxStdDev: 300000000`** — set by hand 2026-07-17, effectively a no-op at this
  metric's scale (real `prefill_token_throughput` values run in the thousands, not
  hundreds of millions), reducing the mechanism to "pick the highest-throughput
  window among the samples" with no real stability requirement. That's a deliberate
  choice here, not an oversight — flagged in case it should be tightened once this
  study's own baseline/sweep data is in and a genuine flatness requirement turns out
  to matter.

## Latency SLA thresholds — flagged as a starting point, not final

`goal.constraints` uses **TTFT P95 ≤ 1500ms** and **ITL P95 ≤ 300ms** — loosened
2026-07-16 from an initial 1000ms/50ms, still a generic interactive-chat industry
starting point (2026-07-15 decision), **not** derived from `0-explorative`'s own
observed TTFT/ITL numbers. Those numbers (baseline ~38.9s TTFT P95, ~598ms ITL P95,
extracted directly from `0-explorative`'s own export) were measured under
GuideLLM's `--rate-type throughput` — a deliberately *saturating* benchmark
methodology whose whole point is to overload the server, producing huge queueing
delays. They are not a meaningful reference for a latency-bounded SLA. This study's
own ramp-based load pattern (ramping from low load toward saturation) will produce
genuinely comparable data — expect to revisit both thresholds again once the
baseline and first few sweep-driven trials under the current 7-level concurrency
sweep report real numbers, and record whatever change is made here. The same
values are mirrored in `k8s/05-job.yaml`'s `--goodput
"time_to_first_token:1500 inter_token_latency:300"` flag, kept in sync since they
tell the same SLO story from two independent places (Akamas' own enforcement vs.
the load generator's own report).

## Real bugs hit and fixed getting this study's load test running (2026-07-16) — inference-perf era, superseded

**This whole section describes `kubernetes-sigs/inference-perf`, which this study
no longer uses** (replaced by NVIDIA AIPerf, 2026-07-17 — see "Load generator"
below). Kept as historical record, same convention as `0-explorative`'s own
incident log — not because any of these bugs are still live in the current setup.
`k8s/04-inference-perf-config.yaml`, `07-sharegpt-prep-job.yaml`, and
`08-inference-perf-patch.yaml`, referenced throughout this section, have all been
deleted from the repo.

Three independent, real bugs in `kubernetes-sigs/inference-perf` itself (not
config mistakes on our side), found by actually running the baseline and reading
its failures — kept here since they'd otherwise look like mysterious one-off
fixes scattered across `k8s/`:

1. **`get_chat_data()` crashes on ShareGPT data** (`api.type: chat`, our case) —
   `"string indices must be integers, not 'str'"`. Root cause: HF `datasets`' JSON
   loader re-serializes each conversation turn as a JSON string when loading a
   top-level JSON array with a heterogeneous nested schema — this happens at
   *load time*, not because of anything wrong in the source file (verified by
   loading a freshly-written, fully-clean file and seeing the same behavior). The
   sibling `get_completion_data()` already works around this
   (kubernetes-sigs/inference-perf#429); `get_chat_data()` doesn't.
   **Fix**: `k8s/08-inference-perf-patch.yaml` monkey-patches `get_chat_data` with
   the same turn-parsing logic, loaded via a wrapper entrypoint
   (`05-job.yaml`'s `command`) that runs before `inference-perf`'s own `main_cli()`.
2. **OOM on the ShareGPT dataset** — once past bug #1, the job was `OOMKilled` at
   its 8Gi limit. Root cause: a top-level JSON *array* (not JSON Lines) forces HF
   `datasets` to parse the entire ~670MB file into memory before it can iterate at
   all, even with `streaming=True`; with the tool's default multi-worker
   multiprocessing, several workers did this simultaneously.
   **Fix**: `k8s/07-sharegpt-prep-job.yaml` now writes the cleaned dataset as true
   JSON Lines (one object per line, `.json` extension kept only because
   `HFShareGPTDataGenerator.__init__` requires it) — confirmed this also made
   conversation turns come back as real dicts, not strings, making fix #1 a
   defense-in-depth rather than strictly load-bearing.
3. **Preprocessing hangs forever after its own timeout** — `load.sweep`'s
   automatic saturation-point discovery timed out as designed
   (`"Loadgen timed out after 60.00s"`), but the job then hung indefinitely.
   Root cause, confirmed directly: `run_stage()`'s post-timeout cleanup waits in a
   loop for `active_requests_counter` to reach 0 — but vLLM's own
   `num_requests_running`/`num_requests_waiting` were already both 0 (server had
   nothing in flight), while the client's counter never cleared. A client-side
   bookkeeping bug, not a model or dataset problem — ruled out by checking vLLM's
   own metrics directly rather than assuming.
   **Fix**: bypassed `load.sweep` entirely — `k8s/04-inference-perf-config.yaml`
   uses explicit `stages` (rate 0.2→2.5 req/s, 60s each) instead of letting the
   tool auto-discover the saturation point. The exact rate range is a rough guess
   (see that file's own comment), not derived from this study's own data — flagged
   for recalibration alongside the other placeholder values in this README.
4. **Every chat request generated ~30 output tokens flat, regardless of stage/rate**
   — confirmed from a real completed run's report (`Token Length Aggregates` showed
   Output Mean/Med/P90 all ≈30 across every one of the 10 original stages, while
   Prompt lengths were genuinely variable, 1300-1600+ tokens). Root cause: unlike
   `get_completion_data` (which sets `CompletionAPIData.max_tokens` from the real
   assistant turn's token count), `get_chat_data` never sets
   `ChatCompletionAPIData.max_tokens` at all — it defaults to 0, and
   `OpenAIModelServerClient.process_request` falls back to
   `self.client.max_completion_tokens`, hardcoded to **30** in
   `client/modelserver/openai_client.py`, whenever a request's own `max_tokens` is 0.
   Every chat request was silently capped at 30 output tokens no matter how long the
   real ShareGPT response actually was — undermining the realistic-load goal (only
   half-realistic: variable prompts, uniform outputs).
   **Fix**: `k8s/08-inference-perf-patch.yaml`'s patched `get_chat_data` now sets
   `max_tokens` from the real last turn's token count (`self.tokenizer.count_tokens`),
   mirroring `get_completion_data`'s own approach. Verified with a single-stage
   smoke test (rate=5, 60s) before rolling into the real ramp: Output Mean/Med/P90
   went from a flat 30/30/30 to a realistic 283.3/249.0/553.0.

Also **reduced the ramp from 10 stages to 6** (2026-07-16): a full 10-stage/60s run
took **~43 minutes** end-to-end once real queueing set in near saturation (see
"Windowing" above — `run_stage()` waits for every enqueued request to finish, not
for the nominal `duration` to elapse, so stage time balloons well past 60s as the
system saturates). Not tractable across an `optimize` step with up to 1000
experiments. 6 stages trades some resolution on exactly where the SLA breaks for a
per-trial cost that's actually survivable.

5. **The original 1-20 req/s range was itself the reason the run above looked
   "flat-bad" instead of a rising ramp, and reported miserable numbers (TTFT into
   the minutes)** — confirmed 2026-07-16 by comparing observed peak
   `prefill_token_throughput` (~4000 tok/s on this A10G) against what the range
   actually demanded. Real ShareGPT prompts are long (observed mean ~1400-1600
   tokens, P90 ~2200-2350) — far heavier than `0-explorative`'s fixed 512-token
   synthetic prompts. At `rate=20 req/s`, sustaining ~1500-token prompts needs
   ~30000 tok/s of prefill alone — roughly 7-8x more than this hardware delivers.
   Every stage in the original range was already deep in saturation, including the
   low end, which is exactly why the ramp never showed a rising trend: there was no
   under-saturated segment left to contrast against.
   **Fix**: rate range revised to **0.2-2.5 req/s** — 4000/1500 ≈ 2.6 req/s as a
   rough prefill-only ceiling, with headroom cut for decode work competing on the
   same GPU/KV-cache. Still a placeholder pending this range's own baseline data.

## Load generator: `inference-perf` → NVIDIA AIPerf (2026-07-17)

### Why switch

Beyond the 5 real bugs in the section above, `inference-perf`'s fundamental load
model was the wrong shape for this study's actual goal. It's **open-loop,
rate-based**: new requests are issued at a fixed rate regardless of whether the
server has finished previous ones. Once the offered rate exceeds the server's real
capacity, the request queue grows **without bound** — this is exactly what made
stage durations balloon from a nominal 60s to 40+ minutes near saturation (see
"Real bugs" #3/#5 above), forcing repeated manual rate-range recalibration
(1-20 → 0.2-2.5 req/s) with no principled way to know the right ceiling in advance
for a config Akamas hasn't tested yet.

NVIDIA AIPerf supports a **closed-loop, concurrency-based** model instead: N
"virtual users," each waiting for its previous request to fully complete before
sending the next. This is self-limiting by construction — a slow/saturated config
just shows higher latency per request, but the total wall-clock time for a
time-boxed run stays bounded regardless of how far past capacity the concurrency
level is. No more guessing a rate ceiling that varies per vLLM configuration.

(A tempting alternative was AIPerf's own `max-goodput-under-slo` search recipe — a
built-in Bayesian search over concurrency that directly optimizes the same
"goodput under TTFT/TPOT/E2E SLOs" objective this study's `goal` already encodes.
Not used here: its search doesn't sweep concurrency monotonically, which would
break this study's `windowing` (built on the assumption of a roughly ordered load
progression), and using its result as the score would mean teaching Akamas to read
AIPerf's own `search_history.json` instead of vLLM's raw Prometheus metrics — a
bigger architectural change than swapping the load generator. Worth revisiting
later; not today's problem to solve.)

### Sizing the concurrency sweep for this specific hardware/model/dataset

`--concurrency 16,32,48,72,108,150` (bumped from `16,32,48,64,80,96` 2026-07-20 —
see "Windowing still lands on the last rung" below), 300s per level
(`--benchmark-duration 300`).

**History**: originally sized from Little's Law (`concurrency ≈ throughput ×
latency`), landing on `1,2,4,8,16,32,64` (~36 estimated saturation point,
bracketed between 32 and 64), later trimmed to `1,2,4,8,16,32` (6 levels, 300s
each) on explicit request. Once real trials ran on this list, a real problem
surfaced: with the study's own `baseline` config (`gpu_memory_utilization=0.90`,
everything else at vLLM's own defaults — nothing else rendered), the system
never saturates within `1-32` — `windowing.stability` (which selects the highest
*stable* `prefill_token_throughput` window) always lands on the *last* rung of
the ramp, because throughput is still climbing there, not because that rung is
actually the server's limit. That makes it hard to see any tuning impact: there's
no "good vs bad" latency contrast within the observed range for Akamas'
`goal.constraints` (TTFT/ITL P95) to actually bind against.

**Fixed 2026-07-17 with real cluster measurements**, not another estimate: with
Akamas paused, redeployed the exact baseline vLLM config (confirmed rendered
args: only `--gpu-memory-utilization=0.90`, no other flags — vLLM's own stock
defaults for everything else) and ran manual AIPerf sweeps at `--benchmark-duration
60` (fast iteration) against it directly:

- First pass, `64,96,128,192,256,384`: goodput (SLA-compliant req/s) peaked
  ~5.27-5.31 across 64-128, then collapsed to 2.66 by 256 and 0.52 by 384 — a
  real saturate-then-collapse curve, but TTFT P90 was *already* ~1517ms (past the
  1500ms SLA) at the very first level tested (64), meaning the useful transition
  zone sits *below* 64, not above it.
- Second pass, `16,32,48,64,80,96` (smaller, constant +16 steps, no more
  16→64-style jumps), confirmed the transition directly:

  | Concurrency | TTFT avg | TTFT P90 | Goodput vs. raw req throughput |
  |---|---|---|---|
  | 16 | 143ms | 365ms | 2.05 = 2.05 (zero SLA violations) |
  | 32 | 184ms | 378ms | 3.85 = 3.85 (zero SLA violations) |
  | 48 | 247ms | 530ms | 5.29 = 5.29 (zero SLA violations) |
  | 64 | 301ms | 981ms | 6.07 vs 6.10 (saturation begins) |
  | 80 | 412ms | 1032ms | 5.60, declining |
  | 96 | 597ms | 1808ms | 5.36, declining further |

  TTFT is the binding constraint here, not ITL (ITL avg stays under 70ms through
  96, nowhere near its 300ms limit at this concurrency range). Saturation begins
  right at the 4th of 6 levels (64) — close to the middle of the ramp, as
  intended, with 3 clean under-SLA levels before it and 2 visibly-degrading
  levels after.

**Caveat, not yet re-validated**: this whole exploration used `--benchmark-duration
60` for fast iteration; the real study runs each level for 300s. Longer sustained
load could shift the true knee somewhat *lower* than 64 (not higher) — cumulative
effects a 60s burst won't show yet (KV-cache pressure, rising preemption rate)
only build up over sustained load, and Akamas' own `windowing.stability` also
gets 5x more samples per level to judge stability against, which a 60s window
doesn't exercise the same way. Not re-tested at 300s before committing this list
(would cost ~15 more minutes for just the 48/64/80 range) — flagged here so a
future look at real Akamas trial data checks whether the observed windowing point
still lands near level 4, not just assumes this holds.

Total sweep time: 6 x 300s = 30 min, plus a one-time ~5 min ShareGPT
dataset-validation pass on the very first Akamas trial ever (see "Token length
cap on ShareGPT" below) — ~35 min first run, ~30 min every run after.
`windowing.stability.width` stays at 6 (one sample per concurrency level, same
alignment philosophy as the old rate-based ramp) — unchanged since the level
*count* didn't change, only the concurrency values.

### Windowing still lands on the last rung even on `16,32,48,64,80,96` (2026-07-20)

Once real Akamas trials ran against the list above (both `baseline` and
`optimize`-step experiments), `windowing.stability` kept selecting the *last*
level (96) as the max-throughput stable window — the exact problem the list
above was sized to avoid, still happening. Root-caused by reading Akamas' own
live docs (`windowing-strategy.md`, `goal-and-constraints.md`), not guessed:

> stability windowing "discard[s] temporal intervals in which a given metric is
> not stable and selects the temporal interval in which a metric is maximized or
> minimized" — and constraint metrics are "aggregated by default by average"
> over that **same already-selected** window.

I.e. `windowing.stability` picks the window by maximizing `prefill_token_throughput`
alone — it has no awareness of `goal.constraints.absolute` (TTFT/ITL P95) at
selection time; constraints are only checked *afterward*, against whichever
window got picked. This matters because **raw prefill throughput doesn't peak
where SLA breaks** — our own exploration data (the `64,96,128,192,256,384` first
pass above) shows AIPerf's own `goodput` (SLA-compliant req/s) collapsing from
5.3 to 0.52 between 128 and 384, while raw output token throughput was still
~842 tok/s at 192, only really cratering by 384. Raw throughput and SLA-compliant
throughput peak at very different concurrency levels — so no matter how the
concurrency list is chosen, `windowing.stability` will keep sliding to the top
rung as long as raw throughput is still climbing there, which based on the data
above is likely somewhere past 250-350 for the baseline config, deep into
already-broken-latency territory.

**Not fixed today** — this is a real architectural gap (windowing metric ≠
SLA-aware metric), flagged for a future look, not resolved by a bigger
concurrency list alone. Candidate fixes considered but not implemented:
changing what `windowing.stability.metric` targets, or feeding AIPerf's own
per-level `goodput`/`good_request_fraction` (already computed and written to
each run's `sweep_aggregate/profile_export_aiperf_sweep.json` — see "AIPerf
artifact files" below) into Akamas as an additional signal.

**Interim, partial mitigation applied 2026-07-20**: bumped the sweep to
`16,32,48,72,108,150` (same 6 levels, ~1.5x steps from 48 up instead of +16
fixed) — a moderate push, explicitly expected to still land near the top rung
for at least some tuned configs, not a fix for the root cause above. Chosen
over an aggressive 300+ ceiling to keep the sweep at 6 levels without
first re-validating a wider range; revisit if `windowing` still pins to 150
once real trial data comes in.

### AIPerf artifact files: what's kept and why (2026-07-20)

Each `aiperf-<timestamp>/` run directory was consuming **~370MB** — with
`numberOfExperiments: 1000` in the `optimize` step, that's ~370GB over a full
study, and the 10Gi `aiperf-results` PVC actually filled completely and started
failing every experiment (`OSError: [Errno 28] No space left on device`) after
~26 trials. Inspected what's actually in one of these directories before
deciding what to do about it:

- **`concurrency_N/inputs.json` (×6, ~56MB each, ~90% of the total size)**:
  a byte-for-byte redundant copy of the same dataset already cached at
  `sharegpt-cache/inputs.json` — every level, every trial, re-writes the
  identical 73k-conversation file for no reason. Zero unique information.
- **`concurrency_N/profile_export.jsonl` (×6, ~2.7-10MB/level)**: genuinely
  useful per-request raw records (TTFT/ITL/latency/HTTP breakdown for every
  single request) — the only place with this granularity; Akamas itself never
  reads it (it scores from Prometheus).
- **`sweep_aggregate/profile_export_aiperf_sweep.json` (112KB)**: a ready-made
  per-concurrency-level summary across the whole sweep, including AIPerf's own
  `goodput`/`good_request_fraction`/latency percentiles — the most useful single
  file here, and a candidate input if the windowing gap above ever gets a real
  fix (see previous section).
- **`aggregate/concurrency_N/*`, `run_config.json`, `logs/aiperf.log`**: small,
  cheap, useful for debugging a specific trial.

**Fix applied**: `05-job.yaml` now wipes every previous run's output
(`find /benchmarks -mindepth 1 -maxdepth 1 -name 'aiperf-*' -exec rm -rf {} +`)
at the start of each run, before generating new output — sparing only
`sharegpt-cache/` (name doesn't match the pattern). Nothing here is scored by
Akamas or needed past the run that produced it, so nothing is lost; this just
guarantees the PVC never fills up again regardless of how many trials the study
runs. Manually cleared the already-full PVC once (26 stale `aiperf-*`
directories, back down to the 126MB `sharegpt-cache` alone) to unblock the
study immediately.

### Token length cap on ShareGPT (2026-07-17) — built-in, not a config choice

The AWS SageMaker blog referenced when this study switched load generators (see
"Why switch" above) caps its prompt/output token lengths explicitly, via
synthetic `mean`/`stddev` overrides. AIPerf's real ShareGPT loader takes a
different approach, confirmed by reading its source directly (`aiperf==0.11.0`,
`src/aiperf/dataset/loader/base_public_dataset.py` and `sharegpt.py`, plus a full
repo-wide grep to rule out any CLI/config override elsewhere): every conversation
is validated against **hardcoded** bounds — `min_seq_len=4`, `max_prompt_len=1024`,
`max_total_len=2048` (prompt + output tokens combined) — adopted directly from
vLLM's own `benchmarks/benchmark_dataset.py`. Conversations outside these bounds
are silently skipped, not truncated. Neither `ShareGPTLoader` nor any CLI flag in
this codebase exposes these three numbers as configurable — there is no
`--dataset-filter` or `--max-prompt-len` equivalent for the public ShareGPT
loader, so there's nothing to add on top: AIPerf already imposes a length cap by
construction whenever `--public-dataset sharegpt` is used, no config change needed
or possible here.

Practical consequence for the sizing above: the ~1400-1600 token prompt mean
(P90 ~2200-2350) used in the Little's Law estimate came from `inference-perf`'s
*unfiltered* ShareGPT sampling — well above AIPerf's 1024-token prompt cap. With
AIPerf, every prompt actually sent will be ≤1024 tokens, so the real effective
mean will be lower and per-request latency likely somewhat below the ~14.5s
estimate above. Not re-deriving the concurrency list over this: the chosen range
(1-64) is wide enough to still bracket the true saturation point regardless, but
flagging this so the ~36 figure isn't read as more precise than it is once real
run data is available.

### What's simpler now

No separate dataset-prep Job (`06-sharegpt-dataset-pvc.yaml` /
`07-sharegpt-prep-job.yaml` are gone) — AIPerf downloads and caches the raw
ShareGPT file itself (`--public-dataset sharegpt`), confirmed against its own
docs and a real tutorial run showing genuinely variable output lengths (142-245
tokens) without any synthetic-length override. A plain `hf-cache` PVC
(`06-hf-cache-pvc.yaml`, mounted at `/root/.cache/huggingface`) persists that
raw-file cache across trials, same re-download-avoidance goal as before with far
less custom machinery. No monkey-patch (`08-inference-perf-patch.yaml` is gone) —
none of `inference-perf`'s bugs apply to a different tool.

Correction to that claim, found 2026-07-17 during the manual cluster test below:
caching the raw ShareGPT *file* isn't the expensive part. **Validating and
tokenizing** its 73,499 conversations against the live tokenizer is — confirmed
from a real run's logs, ~4-5 minutes, and it reruns in full for *every*
concurrency level, because AIPerf starts a fresh `AIPerfSystem` per level and the
`ShareGPTLoader` always re-validates the entire dataset regardless of how much of
it a given level actually uses. Visibly, this is the stall/drop between every
step of the ramp in Grafana the manual test surfaced. So a lightweight prep step
*is* back, just not the old one: `05-job.yaml` now runs a throwaway
`aiperf profile` pass (`--concurrency 1 --benchmark-duration 1`) once to produce
AIPerf's own `inputs.json` (confirmed via source —
`dataset_manager.py`'s `_generate_input_payloads()` dumps the *entire* loaded/
validated dataset, not just whatever got sent during that throwaway pass), caches
it at `/benchmarks/sharegpt-cache/inputs.json` on the existing `aiperf-results`
PVC (so it also survives across Akamas trials, not just across the 7 levels of
one trial), and the real 7-level sweep then loads it back with
`--input-file .../inputs.json --custom-dataset-type inputs_json` — a real,
registered AIPerf loader (`aiperf/plugin/plugins.yaml`'s
`custom_dataset_loader.inputs_json` entry) that replays payloads verbatim with no
re-tokenization/re-validation pass. Net effect: the ~4-5 minute validation cost
now happens once ever (first Akamas trial only), not 7 times per trial.

One thing carried over unchanged: AIPerf's `--tokenizer` also defaults to
`--model-names`, and `qwen2.5-7b` (vLLM's served name) isn't a valid HF repo id for
tokenizer lookup — same class of issue `inference-perf` had (see "Real bugs"
above), fixed the same way: `--tokenizer Qwen/Qwen2.5-7B-Instruct` set explicitly.

## Incidents found during the `optimize` step (2026-07-16)

Real crashes hit by actual sampled experiments once the study was running —
kept here the same way `0-explorative` documents its own incidents, so they
read as known/root-caused rather than mysterious recurring failures. All three
are tolerated by `maxFailedExperiments: 200` (the study keeps running), but the
first two are worth a `parameterConstraints` fix since they're either fully or
partially avoidable in advance, unlike ordinary resource-contention noise.

1. **KV cache budget exhausted by speculative decoding + a large `max_num_seqs`**
   (experiment 4) — `vllm serve` refused to start:
   `ValueError: To serve at least one request with the model's max seq len
   (32768), (1.75 GiB KV cache is needed, which is larger than the available
   KV cache memory (1.49 GiB)`. Root cause: `spec_method=ngram_gpu` +
   `spec_tokens=7` + `max_num_seqs=867` + `max_cudagraph_capture_size=160` +
   `optimization_level=2` together consumed enough of the
   `gpu_memory_utilization`-bounded budget that too little was left for KV
   cache to cover even one sequence at the pinned `max_model_len=32768` —  the
   same class of memory-accounting gap as `0-explorative`'s own sampler-warmup
   OOM incident (see that study's README), just with speculative decoding as
   the new contributing factor. Not (yet) covered by any `parameterConstraints`
   entry.
2. **`spec_method=mtp` is not implemented by the installed vLLM version at all**
   (experiment 6) — hard, deterministic failure, not a resource issue:
   `NotImplementedError: Unsupported speculative method: 'mtp'`, raised
   unconditionally by vLLM 0.22.0's own `SpeculativeConfig.__post_init__`
   regardless of any other parameter. Likely requires either a newer vLLM
   version or a model with a native MTP head (e.g. DeepSeek-V3) — Qwen2.5-7B
   has neither. Every sampled `spec_method=mtp` trial fails 100% of the time —
   a genuine pack-vs-installed-version domain mismatch (the pack's
   `spec_method` categories include a value this vLLM build can't run), same
   class of issue as `0-explorative`'s `block_size=106` incident. **Fixed
   2026-07-16**: removed `mtp` from `vLLM.spec_method`'s categories in
   `parametersSelection` — a categorical, unconditional failure like this isn't
   avoidable via `parameterConstraints`, only by not offering the value at all.
3. **`spec_method=ngram_gpu` + `optimization_level=0` crashes at engine-core
   init** (experiment 7) — also deterministic:
   `ValueError: No compilation mode is set`, raised from
   `NgramProposerGPU`'s kernel (`NgramGPUKernel`), which is itself implemented
   via vLLM's `@support_torch_compile` machinery and unconditionally requires
   an active compilation backend — but `optimization_level=0` sets
   `compilation_config.mode = CompilationMode.NONE` (compilation fully
   disabled), regardless of what other parameters are set. Unlike #2 and #4,
   this is an *interaction* between two parameters rather than one
   categorically unsupported value, so it's fixable with a
   `parameterConstraints` entry rather than a domain change. **Fixed
   2026-07-16**: `vLLM.spec_method != "ngram_gpu" || vLLM.optimization_level
   != 0` added to `akamas/1-Goodput-Realistic-Load.yaml`.
4. **`spec_method=suffix` requires a third-party package that isn't installed**
   (experiment 8) — also a hard, deterministic failure:
   `ImportError: Arctic Inference is required for suffix decoding. Install via
   pip install arctic-inference==0.1.1`, raised from vLLM's own
   `SpeculativeConfig._validate_suffix_decoding()`. This was initially
   suspected of sharing #3's compilation-backend crash (same GPU-kernel family
   as `ngram_gpu`) but turned out to be a completely unrelated cause — a
   missing dependency in the `vllm/vllm-openai:v0.22.0` image, not present for
   any parameter combination. **Fixed 2026-07-16**: removed `suffix` from
   `vLLM.spec_method`'s categories alongside `mtp` — same reasoning as #2, a
   categorical failure with no parameter combination that avoids it.
5. **`spec_method=ngram` + `async_scheduling=true` rejected by vLLM's own config
   validation** (experiment 16) — fails even earlier than #3/#4, at Pydantic
   config-construction time, before engine-core start:
   `ValidationError: Currently, async scheduling is only supported with
   EAGLE/MTP/Draft Model/NGram GPU kind of speculative decoding`. Note this is
   **"NGram GPU" specifically, not plain "ngram"** (CPU-based) — the two are
   different pack categories, and only the GPU variant is on vLLM's own
   supported-with-async-scheduling list. Same class of interaction as #3 (two
   parameters, not one broken value), so fixable the same way. **Fixed
   2026-07-16**: `vLLM.spec_method != "ngram" || vLLM.async_scheduling ==
   "false"` added to `akamas/1-Goodput-Realistic-Load.yaml`.

`spec_method`'s domain was `[none, ngram, ngram_gpu]` after removing `mtp`/`suffix`
(#2, #4), with two `parameterConstraints` entries guarding the `optimization_level`
and `async_scheduling` interactions (#3, #5) — but after 5 distinct crashes in a
single `optimize` step, all traceable to this one parameter family, the call was
made to stop patching around individual interactions one at a time.

**Superseding update, 2026-07-17**: `spec_method`/`spec_tokens` and all 4 of their
`parameterConstraints` entries (both sentinel-gates plus #3 and #5 above) have been
**removed from this study entirely** — see "Parameters tuned" and "Parameter
constraints" above. This section is kept as the historical record of *why*, per this
repo's incident-logging convention (`0-explorative` does the same for its own
crashes) — not because any of these 5 issues are still live in the current config.

## Prerequisites still open before this study can be created

1. ~~Confirm the installed vLLM pack actually reports `1.5.1`~~ — done, pack
   re-installed/updated on the live Akamas instance (2026-07-16).
2. ~~`akamas/id_rsa` does not exist in this study's folder~~ — a key now exists locally
   at `studies/1-goodput-realistic-load/akamas/id_rsa`. **Not committed to git**
   (`.gitignore`'s `id_rsa`/`id_rsa.*` rules were found disabled and have been
   re-enabled, 2026-07-16) — confirm separately that this same file is reachable at
   `/work/vllm-benchmark/studies/1-goodput-realistic-load/akamas/id_rsa` on the actual
   `toolbox` host the workflow's tasks run against, since that path is what the
   workflow YAML references, not this git checkout.
3. ~~Verify `inference-perf`'s exact behavior end-to-end at least once manually~~ —
   moot, `inference-perf` has been replaced by AIPerf (2026-07-17, see "Load
   generator"). **Verify AIPerf's exact behavior end-to-end at least once manually**
   before trusting it inside an Akamas experiment loop instead — neither tool has a
   track record in this repo, so the same caution applies to the replacement. Still
   open.

## How to run

See `infra/README.md` for the full cluster-provisioning flow (steps 1-2 are the same
as `0-explorative`'s, since this study reuses that cluster). Once the cluster and
monitoring stack are confirmed up:

```bash
# confirm the vLLM pack reports 1.5.1 (see "Prerequisites" above)
akamas list optimization-pack

akamas create -f studies/1-goodput-realistic-load/akamas/
akamas start study "1-Goodput-Realistic-Load"
```

## Results

<Filled in by the study-recap skill once the study finishes.>

## Conclusions

<Filled in by the study-recap skill once the study finishes.>
