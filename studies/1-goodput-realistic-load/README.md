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
   saturation point (10 stages × 60s), not a single fixed-rate throughput-seeking
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
  (`quay.io/inference-perf/inference-perf:latest`), `data.type: shareGPT` (real
  dataset, auto-fetched from the Hugging Face Hub —
  `anon8231489123/ShareGPT_Vicuna_unfiltered`, confirmed from the tool's own source,
  no local file needed), `load.sweep` (linear, 10 stages × 60s) — see
  `k8s/04-inference-perf-config.yaml`. `api.streaming: true` is required for
  TTFT/ITL/TPOT metrics at all; `x-slo-ttft-ms`/`x-slo-tpot-ms` headers give the
  tool's own report a native `goodput_metrics` block alongside Akamas' own
  `goal.constraints` enforcement.
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
are excluded from computation and left unrendered, so vLLM applies its own real
startup defaults for all of them. The deployed command ends up close to a genuinely
bare `vllm serve <model> --port=8000 --host=0.0.0.0 --served-model-name=...
--enable-mfu-metrics --gpu-memory-utilization=0.90`, not every tunable flag re-stated
at a default value. The `optimize` step sets neither of these fields, so Akamas stays
fully free to pick any `parametersSelection` value there — this restriction is
baseline-only.

This is a deliberate 2026-07-15/16 design, arrived at over two corrections:

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
   would fail outright on the baseline's now-unsubstituted `${vLLM.*}` tokens.
3. `apply_config.sh`'s Step 2 (`k8s/apply_config.sh`) strips any line still containing
   a literal unsubstituted `${vLLM.` token before the file is applied — a generic rule
   that does nothing on optimize-step trials (where every token gets a real computed
   value).

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
This study's load is a **sweep/ramp** (10 stages × 60s, increasing rate) — there is no
single steady state to trim around, so `windowing.type: stability` is used instead:
scan for a temporally stable interval, then, among the stable candidates, pick the one
where a chosen metric is maximized.

```yaml
windowing:
  type: stability
  stability:
    metric: vLLM.prefill_token_throughput
    resolution: "15s"
    width: 4
    maxStdDev: 300
  when:
    metric: vLLM.prefill_token_throughput
    is: max
  task: RunTest
```

- **Same metric for both roles** (`prefill_token_throughput` for both the stability
  check and the `when: max` comparison) — a single-metric pattern, not the
  two-metric split (a separate "has it settled" indicator plus a separate "which one is
  best" comparison) considered earlier. `when: max` naturally favors the highest-
  throughput stable interval, which for a monotonic ramp lands near the highest-load
  stage the server sustains without degrading — i.e. "toward the end of the ramp"
  without hardcoding that assumption, and without penalizing an earlier degradation if
  one occurs.
- **`width: 4`, `resolution: "15s"`** → a 60s stability window, matching one
  `load.sweep` stage duration exactly (`k8s/04-inference-perf-config.yaml`), so the
  window can't straddle two different load levels.
- **`maxStdDev: 300`** is a placeholder sized off `0-explorative`'s own observed
  `prefill_token_throughput` range (~2500-3600 tok/s), not derived from this study's own
  data (which doesn't exist yet). Recalibrate once the baseline and first sweep trials
  report real numbers — same caveat as the latency thresholds below. A much larger
  value (e.g. 1e9) would never reject any window as unstable at this metric's scale,
  reducing the mechanism to "just pick the highest-throughput window" with no real
  stability requirement — that's a valid choice too if a genuine flatness requirement
  turns out not to matter, but isn't the intent here until proven otherwise.

## Latency SLA thresholds — flagged as a starting point, not final

`goal.constraints` uses **TTFT P95 ≤ 1000ms** and **ITL P95 ≤ 50ms** — generic
interactive-chat industry targets (2026-07-15 decision), **not** derived from
`0-explorative`'s own observed TTFT/ITL numbers. Those numbers (baseline ~38.9s TTFT
P95, ~598ms ITL P95, extracted directly from `0-explorative`'s own export) were
measured under GuideLLM's `--rate-type throughput` — a deliberately *saturating*
benchmark methodology whose whole point is to overload the server, producing huge
queueing delays. They are not a meaningful reference for a latency-bounded SLA. This
study's own sweep-based load pattern (ramping from low load toward saturation) will
produce genuinely comparable data — expect to revisit both thresholds once the
baseline and first few sweep-driven trials report real numbers, and record whatever
change is made here.

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
