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

1. **Load generator**: `kubernetes-sigs/inference-perf` instead of GuideLLM, replaying
   the real ShareGPT dataset (multi-turn conversations) instead of GuideLLM's synthetic
   fixed `prompt_tokens=512,output_tokens=128` shape.
2. **Load pattern**: a linear sweep ("ramp") from low load toward this server's own
   saturation point (6 stages × 60s), not a single fixed-rate throughput-seeking
   benchmark — this directly surfaces *where* the latency SLA starts being violated,
   which is exactly the goodput ceiling this study is trying to find.
3. **Parameter surface**: all of `0-explorative`'s 16 tuned parameters, plus the two
   new pack v1.5.1 parameters (`spec_method`/`spec_tokens`, speculative decoding) —
   genuinely explored here for the first time, since n-gram speculation needs no draft
   model and works on any hardware.

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
- **Load generator:** `kubernetes-sigs/inference-perf`
  (`quay.io/inference-perf/inference-perf:latest`), `data.type: shareGPT` with an
  explicit `data.path` pointing at a locally-prepared, cleaned copy of
  `anon8231489123/ShareGPT_Vicuna_unfiltered` (not the tool's own auto-download —
  see "Real bugs hit and fixed" below), `load` as 6 explicit stages of increasing
  rate (0.2 to 2.5 req/s, 60s each), not `load.sweep`'s automatic saturation-point
  discovery — see `k8s/04-inference-perf-config.yaml`. `api.streaming: true` is
  required for TTFT/ITL/TPOT metrics at all; `x-slo-ttft-ms`/`x-slo-tpot-ms`
  headers give the tool's own report a native `goodput_metrics` block alongside
  Akamas' own `goal.constraints` enforcement.
- **Telemetry:** Prometheus (same instance/metric catalog as `0-explorative` —
  `kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`,
  `duration: 30`, `logLevel: DETAILED`). Unaffected by the load-generator switch —
  Akamas reads vLLM's own `/metrics` directly, not inference-perf's report files.

## Parameters tuned

18 of the pack's 30 parameters are searched (0-explorative's original 16, plus the two
new speculative-decoding parameters); 11 are pinned (single GPU, non-MoE model, or a
real incident already root-caused on this exact hardware/vLLM version — see
`0-explorative`'s own README for the incident write-ups, unchanged here since it's the
same stack); 1 (`compilation_mode`) is deliberately excluded, same reason as
`0-explorative` (no direct top-level CLI flag).

| Parameter | Domain / categories | Baseline |
|---|---|---|
| `vLLM.gpu_memory_utilization` | [0.85, 0.95] | **0.90** (explicitly rendered — see "Baseline rendering" below) |
| `vLLM.max_num_seqs` | [16, 1024] | *(not rendered)* |
| `vLLM.max_num_batched_tokens` | [256, 8192] | *(not rendered)* |
| `vLLM.kv_cache_dtype` | auto, fp8, fp8_e4m3, fp8_e5m2 | *(not rendered)* |
| `vLLM.performance_mode` | balanced, interactivity, throughput | *(not rendered)* |
| `vLLM.optimization_level` | [0, 3] | *(not rendered)* |
| `vLLM.dtype` | auto, float16, bfloat16 | *(not rendered)* |
| `vLLM.enforce_eager` | true, false | *(not rendered)* |
| `vLLM.scheduling_policy` | fcfs, priority | *(not rendered)* |
| `vLLM.prefix_caching_hash_algo` | sha256, sha256_cbor | *(not rendered)* |
| `vLLM.disable_cascade_attn` | true, false | *(not rendered)* |
| `vLLM.tokenizer_mode` | auto, hf, slow | *(not rendered)* |
| `vLLM.async_scheduling` | true, false | *(not rendered)* |
| `vLLM.max_cudagraph_capture_size` | [1, 1024] | *(not rendered)* |
| `vLLM.block_size` | 16, 32, 48, 64, 80, 96, 112, 128 (**ordinal**, not categorical — pack v1.5.1) | *(not rendered)* |
| `vLLM.attention_backend` | FLASH_ATTN, FLASHINFER, TRITON_ATTN | *(not rendered)* |
| `vLLM.spec_method` **(NEW)** | none, ngram, ngram_gpu, suffix, mtp | *(not rendered)* |
| `vLLM.spec_tokens` **(NEW)** | [0, 16] | *(not rendered)* |

### Baseline rendering — a deliberate change from `0-explorative`

`0-explorative`'s baseline `values:` explicitly restated vLLM's own assumed defaults
for every tuned parameter. This study's baseline instead renders **only**
`vLLM.gpu_memory_utilization`, pinned to **0.90**; all other 28 pack parameters
(the 16 other tuned params, `spec_method`/`spec_tokens`, and the 11 pinned params)
are excluded from computation, so the rendered command ends up close to a genuinely
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

**Excluded entirely** (not in `parametersSelection`, not pinned, not referenced by the
deployment template): `vLLM.compilation_mode` — same reasoning as `0-explorative`, no
direct top-level CLI flag exists for it (only reachable via the nested
`--compilation-config` JSON argument).

## Parameter constraints

All 6 carried forward unchanged from `0-explorative` (the `block_size` ones are
unaffected by its categorical→ordinal type change), plus 2 new ones for the
speculative-decoding gate/sentinel pattern:

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
  - name: speculative decoding disabled forces spec_tokens to its off sentinel
    formula: vLLM.spec_method != "none" || vLLM.spec_tokens == 0
  - name: speculative decoding enabled requires a real (non-sentinel) spec_tokens
    formula: vLLM.spec_method == "none" || vLLM.spec_tokens > 0
```

Re-verified 2026-07-15 whether the `TRITON_ATTN`+fp8 exclusions are still needed on
this hardware: **not re-tested** — this study reuses the identical A10G/vLLM 0.22.0
combo `0-explorative` found these crashes on, so the same exclusions are kept rather
than assumed fixed. (They would only plausibly become unnecessary on Hopper+ hardware,
per that incident's own root cause — not relevant here.)

## Windowing — `stability`, not `trim`

`0-explorative`'s single fixed-rate load converges to one steady state, so a `trim`
window (cut a fixed amount off the head/tail) had an obvious, principled cut point.
This study's load is a **sweep/ramp** (6 stages × 60s, increasing rate) — there is no
single steady state to trim around, so `windowing.type: stability` is used instead:
scan for a temporally stable interval, then, among the stable candidates, pick the one
where a chosen metric is maximized.

```yaml
windowing:
  type: stability
  stability:
    metric: vLLM.prefill_token_throughput
    width: 8
    maxStdDev: 300
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
  throughput stable interval, which for a monotonic ramp lands near the highest-load
  stage the server sustains without degrading — i.e. "toward the end of the ramp"
  without hardcoding that assumption, and without penalizing an earlier degradation if
  one occurs.
- **`width: 8`** samples, native/raw resolution (no explicit `resolution` set, so
  Akamas uses the trial's own underlying data-point granularity rather than an
  aggregated bucket size).
- **`maxStdDev: 300`** is a placeholder sized off `0-explorative`'s own observed
  `prefill_token_throughput` range (~2500-3600 tok/s), not derived from this study's own
  data (which doesn't exist yet). Recalibrate once the baseline and first sweep trials
  report real numbers — same caveat as the latency thresholds below. A much larger
  value (e.g. 1e9) would never reject any window as unstable at this metric's scale,
  reducing the mechanism to "just pick the highest-throughput window" with no real
  stability requirement — that's a valid choice too if a genuine flatness requirement
  turns out not to matter, but isn't the intent here until proven otherwise.

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
baseline and first few ramp-driven trials under the recalibrated 0.2-2.5 req/s
range report real numbers, and record whatever change is made here. The same
values are mirrored in `k8s/04-inference-perf-config.yaml`'s `x-slo-ttft-ms`/
`x-slo-tpot-ms` headers, kept in sync since they tell the same SLO story from two
independent places (Akamas' own enforcement vs. inference-perf's own report).

## Real bugs hit and fixed getting this study's load test running (2026-07-16)

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
3. **Verify `inference-perf`'s exact behavior end-to-end at least once manually**
   before trusting it inside an Akamas experiment loop — this tool has not been used
   in this repo before (per `ROADMAP.md` Q2's now-resolved recommendation to commit
   to it directly rather than run a side-by-side validation study first). Still open.

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
