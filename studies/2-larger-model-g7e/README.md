# 2-Larger-Model-G7e

**Status:** TODO
**Dates:** —

## Objective

Same goodput question as `1-goodput-realistic-load` — maximize
`vLLM.prefill_token_throughput + vLLM.decode_token_throughput` subject to a P95 TTFT
and P95 ITL latency SLA (`goal.constraints`) — now asking a **hardware-only** question:
does the exact same model/config that `1-goodput-realistic-load` already tuned on an
A10G behave differently — better, worse, or find a different optimal region — on this
study's GPU (`g7e.4xlarge`, NVIDIA RTX PRO 6000 Blackwell, SM120)? See "Model swap"
below for why this study no longer tests a bigger model, only different hardware for
the same one.

**Model swap (2026-08-27)**: this study originally targeted `Qwen/Qwen3.8-27B` (a ~4x
larger model, see "Hardware swap" below for the hardware side of that original framing)
— **reverted to `Qwen/Qwen2.5-7B-Instruct`**, the exact model `0-explorative`/
`1-goodput-realistic-load` use, following a real run and a joint discussion of why its
result was disappointing. That run (`akamas/2-Larger-Model-G7e.yaml`, 2026-08-24 to
2026-08-25, 22 experiments attempted before being stopped) found only a small
improvement over its own baseline, and two credible, competing explanations for why
surfaced during discussion: (1) `Qwen/Qwen3.8-27B`'s hybrid Mamba/attention (GDN)
architecture stresses vLLM code paths this repo had never exercised before — it caused
two real pre-flight crashes (see "Incidents," kept below for the historical record) and
all 3 in-study experiment errors matched the same known Mamba cache-block ceiling; (2)
this GPU's SM120 kernel maturity is itself an open question this repo had already
flagged (`FLASHINFER`+fp8 kernel-selection rough edges, never actually smoke-tested — see
"Prerequisites still open" #6) and never resolved before the run. Both are plausible
and the run alone couldn't separate them — a bigger, architecturally different model
AND newer hardware changed at the same time. **Reverting the model removes the first
confound entirely**: with the exact model `1-goodput-realistic-load` already has a
clean, SLA-compliant, well-understood baseline and optimum for, any difference this
study now finds is attributable to hardware (g7e.4xlarge/Blackwell SM120 vs.
A10G/Ampere), not to model architecture. A manual `TRITON_ATTN`+fp8 smoke test aimed at
resolving the SM120 kernel-maturity question directly was started but abandoned
mid-flight in favor of this broader reset — worth resuming once this study's own
baseline is reverified on the swapped-back model (see "Prerequisites still open").

**Hardware swap (2026-08-21)**: originally planned on `p5.4xlarge` (1x H100 80GB) — no
capacity available in `us-east-2` at provisioning time. Switched to `g7e.4xlarge` (1x
NVIDIA RTX PRO 6000 Blackwell Server Edition, 96GB **GDDR7**). This is **not** a
like-for-like substitution — it changes what this study can actually conclude:
- **Memory bandwidth**: ~1.6TB/s (GDDR7) vs H100 SXM's ~3.35TB/s (HBM3) — roughly half.
  Decode-phase inference is bandwidth-bound, so `vLLM.decode_token_throughput` (half of
  this study's own goal formula) may be capped by this regardless of the extra 16GB of
  VRAM. The "more capable hardware" framing above should be read as "more VRAM, less
  bandwidth," not a strict upgrade over H100.
- **Kernel maturity (SM120)**: vLLM's CUDA support for this GPU's compute capability
  (12.0, "SM120") has a documented history of rough edges distinct from Hopper (H100,
  SM90) — FP8/FP4 kernel-selection code that assumes "Blackwell == SM100" and silently
  falls back to slower kernels, FlashInfer JIT breakage on some CUDA builds. This
  directly touches two of this study's own tuned parameters, `attention_backend`
  (`FLASHINFER` is one of 3 candidates) and `kv_cache_dtype` (the `fp8`/`fp8_e4m3`/
  `fp8_e5m2` candidates) — verify these empirically on this hardware before trusting
  an experiment that picked one of them (see "Prerequisites still open" #6, new).
- **No MIG support** on this GPU (workstation-class, not a datacenter Hopper/Blackwell
  SXM part) — not a blocker for this study (doesn't test MIG), but breaks the implicit
  "same H100 family" assumption `ROADMAP.md`'s Study #4 carries for MIG right-sizing,
  should this hardware ever be reused there.
- **128GiB system RAM** (`g7e.4xlarge`) vs the originally planned 256GiB
  (`p5.4xlarge`) — still ample for this model, but tighter margin; the Kubernetes
  Deployment's memory limit was lowered accordingly (see `k8s/01-deployment_template.yaml`).

**Redirects `ROADMAP.md` Section B's original Study #2 slot** (2026-08-20, explicit
user decision) — that slot originally planned a `p5.48xlarge` (8x H100) re-baseline of
the *same* Qwen2.5-7B-Instruct model used everywhere else in this repo (Goal A: more
throughput at parity of hardware). This study originally asked a different question
instead (a bigger model, not more GPUs); after the 2026-08-27 model swap above it's
closer to Goal A/B's original framing again (same model, different single-GPU
hardware), but still doesn't test multiple GPUs. **The original Study #2 plan is kept
as a superseded historical record in `ROADMAP.md` Section D** — not deleted — because
Section D's Study #3/#4 both build on its `p5.48xlarge`/Qwen2.5-7B baseline for their
own tensor-parallelism scaling questions; see `ROADMAP.md`'s explicit flag on those two
sections for the reconciliation this redirect leaves open. This study's own scope stops
at "does the same model on different single-GPU hardware improve goodput" — it does not
attempt to answer Goal A/B's multi-GPU right-sizing questions.

## Stack & versions

- **Akamas version:** 3.7.x
- **Optimization pack(s) used:** vLLM **1.5.1**
  (`feature/attention-backend-and-block-size-categorical` branch, commit `9e177fd` —
  `akamas/2-Larger-Model-G7e.yaml` and its components were built against a scratch
  clone of this exact commit, read directly from
  <https://gitlab.com/akamas/optimization-packs/vllm>, not assumed). **TODO — not yet
  verified against a live Akamas instance**: run `akamas describe optimization-pack
  vLLM` before creating these resources for real — don't assume the installed pack is
  still this build. GPU pack: metrics-only, same as prior studies — not independently
  re-verified here either. Kubernetes pack: stock `Kubernetes Container` component
  type, no properties needed.
- **Workload under test:** `Qwen/Qwen2.5-7B-Instruct` (dense, non-MoE — **reverted
  2026-08-27** from `Qwen/Qwen3.8-27B`, see "Model swap" above). The exact same model
  `0-explorative`/`1-goodput-realistic-load` use, on this study's own hardware. Served
  as `qwen2.5-7b`, namespace `llm-serving`.
  - **Image tag reverted to `vllm/vllm-openai:v0.22.0`** (2026-08-27, matching
    `0-explorative`/`1-goodput-realistic-load`'s own pin exactly) — the `v0.27.1` pin
    used for the abandoned `Qwen/Qwen3.8-27B` attempt is no longer needed, that model
    is what required the newer build. **Not yet verified**: `v0.22.0` has never been
    smoke-tested on this GPU's SM120 compute capability — only ever run on A10G/Ampere
    (prior studies) or, briefly, `v0.27.1` on this g7e node (abandoned 27B attempt) —
    do this before trusting an Akamas run (see "Prerequisites still open").
  - No MTP (multi-token prediction) draft head on this model (unlike the abandoned
    `Qwen/Qwen3.8-27B` attempt) — `spec_method`/`spec_tokens` stay excluded regardless
    (see "Parameters tuned" below): `1-goodput-realistic-load` hit 5 distinct crashes
    across its own `optimize` step trying speculative decoding on this exact model, so
    it's deliberately not attempted here either, for the same directly-applicable
    reason (not a different-model analogy anymore).
- **Cluster / hardware:** single NVIDIA RTX PRO 6000 Blackwell Server Edition 96GB GPU
  via AWS **`g7e.4xlarge`** (16 vCPU, 128GiB RAM) — **swapped 2026-08-21** from the
  originally planned single H100 80GB via `p5.4xlarge` (16 vCPU, 256GiB RAM; confirmed
  2026-08-20 via AWS's own P5-single-GPU announcement), due to no `p5.4xlarge` capacity
  in `us-east-2` at provisioning time. See "Hardware swap" above for what this changes
  — not the 8-GPU `p5.48xlarge` the original Study #2 plan used either way.
  **Deliberately reuses the same `vllm-bench` EKS cluster** as `0-explorative`/`1-goodput-realistic-load`
  (explicit user decision, 2026-08-20) via a **new, separate managed node group**
  (`llm-serving-g7e`) rather than a standalone cluster — see `infra/README.md`. This
  study still keeps its own full `infra/` copy per this repo's atomic-per-study
  convention, but `infra/eks/provision.sh` detects the cluster already exists and adds
  only the missing `llm-serving-g7e` node group (now `g7e.4xlarge`, RTX PRO 6000
  Blackwell), leaving the existing `system`/`akamas`/`llm-serving`
  (A10G) node groups untouched. **The A10G `llm-serving` node group is currently scaled
  to 0** (2026-08-20) — so there's no live scheduling conflict either way — but the vLLM
  Deployment's `nodeSelector`/`tolerations` (see `k8s/01-deployment_template.yaml`)
  explicitly target `llm-serving-g7e` regardless; placement doesn't rely on the other
  node group staying off. Same `llm-serving`/`llm-benchmark` namespaces as
  `1-goodput-realistic-load`, reused as-is — only the node group differs.
- **Load generator:** same tool and methodology as `1-goodput-realistic-load`: NVIDIA
  AIPerf, `--public-dataset sharegpt` (real ShareGPT replay), closed-loop concurrency
  sweep, `windowing.stability`. That study's *current* concurrency list
  (`150,179,213,253,302,359,428,509,606,722,860,1024`, 12 levels, 300s each) and SLA
  thresholds (TTFT P95 ≤ 1500ms, ITL P95 ≤ 300ms) were calibrated specifically for
  Qwen2.5-7B-Instruct on an A10G — see that study's own README, "Sizing the
  concurrency sweep," for the full multi-week calibration process this had to go
  through. **Model is no longer a confound** (2026-08-27 model swap, see "Model swap"
  above) — this study now uses that exact same model, so the carried-forward numbers
  are a much more reasonable starting point than before. Only the GPU differs (RTX PRO
  6000 Blackwell vs. A10G — roughly half H100's memory bandwidth, but 96GB vs 80GB VRAM
  gives more KV-cache headroom, and this is a different, more capable GPU than the
  A10G those numbers were actually calibrated on either way), so the true saturation
  point could still land at a different concurrency — a real manual exploratory check
  before trusting this list for an `optimize` step is still worthwhile, just a smaller
  risk than when the model also differed.
- **Telemetry:** Prometheus, same instance/metric catalog as prior studies
  (`kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`,
  `duration: 30`, `logLevel: DETAILED`) — reused as-is since telemetry reads vLLM's own
  `/metrics`, independent of model/hardware. Per `ROADMAP.md` Q7, this repo's telemetry
  config has never been independently re-verified against a live vLLM `/metrics`
  endpoint — worth doing once for this study too, not assumed inherited-and-correct.

## Parameters tuned

The same 14 tunable parameters as `1-goodput-realistic-load` (see that study's README
for the full per-parameter rationale, largely hardware-independent), now built into
`akamas/2-Larger-Model-G7e.yaml`. **Baseline design now matches
`1-goodput-realistic-load`'s `doNotRenderParameters` pattern exactly**: every
tuned/pinned parameter referenced by the deployment template is excluded from baseline
rendering (so vLLM applies its own real default) *except* `gpu_memory_utilization`
(pinned to 0.90, since the pack's own `defaultValue` of 0.92 doesn't match what this
baseline wants). A `max_num_seqs: 256` pin was needed for a time (see "Incidents"
below) while this study targeted `Qwen/Qwen3.8-27B` — its hybrid Mamba/attention
architecture made vLLM's own auto-selected default for it unsafe. **Removed 2026-08-27**
along with the model swap back to `Qwen2.5-7B-Instruct`, which doesn't need it (same as
`1-goodput-realistic-load`). The "Baseline" column below shows the pack's own
`defaultValue` for reference, not what actually renders — every row except
`gpu_memory_utilization` is left unrendered at baseline (`doNotRenderParameters`) and
only takes its shown value during `optimize`, when Akamas' `parametersSelection` search
picks a real value for it.

| Parameter | Domain / categories | Baseline (rendered) |
|---|---|---|
| `vLLM.gpu_memory_utilization` | [0.85, 0.95] | **0.90** (pinned) |
| `vLLM.max_num_seqs` | [16, 1024] | not rendered (vLLM default) |
| `vLLM.max_num_batched_tokens` | [256, 8192] | not rendered (vLLM default) |
| `vLLM.kv_cache_dtype` | auto, fp8, fp8_e4m3, fp8_e5m2 | not rendered (vLLM default) |
| `vLLM.performance_mode` | balanced, interactivity, throughput | not rendered (vLLM default) |
| `vLLM.optimization_level` | [0, 3] | not rendered (vLLM default) |
| `vLLM.enforce_eager` | true, false | not rendered (vLLM default) |
| `vLLM.scheduling_policy` | fcfs, priority | not rendered (vLLM default) |
| `vLLM.disable_cascade_attn` | true, false | not rendered (vLLM default) |
| `vLLM.tokenizer_mode` | auto, hf, slow | not rendered (vLLM default) |
| `vLLM.async_scheduling` | true, false | not rendered (vLLM default) |
| `vLLM.max_cudagraph_capture_size` | [1, 1024] | not rendered (vLLM default) |
| `vLLM.block_size` | 16, 32, 48, 64, 80, 96, 112, 128 (ordinal) | not rendered (vLLM default) |
| `vLLM.attention_backend` | FLASH_ATTN, FLASHINFER, TRITON_ATTN | not rendered (vLLM default) |

**Pinned** (not in `parametersSelection`; the "Value" column is the *intended* fixed
value — same 12 as `1-goodput-realistic-load` except `spec_method`/`spec_tokens`, see
"Excluded" below). Per the baseline redesign above, none of these render at
`baseline` — excluded via `doNotRenderParameters`, so vLLM's own default applies
there instead. **Open question, not yet verified**: since none of these 12 are in
`values` (baseline or otherwise) or `parametersSelection`, and the `optimize` step
sets no `doNotRenderParameters` of its own, whether they render at the value shown
here during `optimize` depends on whether Akamas renders every component-declared
parameter at its pack `defaultValue` by default (in which case the shown value only
takes effect if it happens to equal the pack's own default) or leaves
non-`values`/non-`parametersSelection` parameters unrendered everywhere, always —
this repo hasn't confirmed which with Akamas support or a live `optimize` trial yet.
`max_model_len` in particular matters here: if it never actually renders, vLLM falls
back to this model's native 262144 context instead of the deliberately chosen 32768
(memory-safety headroom, not an arbitrary choice) — worth confirming before trusting
any `optimize`-step KV-cache-budget-related result.

| Parameter | Value | Why |
|---|---|---|
| `vLLM.tensor_parallel_size` | 1 | Single GPU (`g7e.4xlarge` has exactly one RTX PRO 6000 Blackwell). |
| `vLLM.pipeline_parallel_size` | 1 | Same. |
| `vLLM.data_parallel_size` | 1 | Same. |
| `vLLM.enable_expert_parallel` | false | Qwen2.5-7B-Instruct is dense, not MoE. |
| `vLLM.disable_custom_all_reduce` | false | Only relevant at `tensor_parallel_size > 1`. |
| `vLLM.decode_context_parallel_size` | 1 | Context parallelism needs multiple GPUs. |
| `vLLM.prefill_context_parallel_size` | 1 | Same. |
| `vLLM.max_model_len` | 32768 | Carried forward from `1-goodput-realistic-load` — well within the pack's own `max_model_len` domain ceiling ([1, 131072]), though far below this model's native 262144 context. |
| `vLLM.max_num_partial_prefills` | 1 | Carried-forward incident avoidance — see `0-explorative`'s README; **not re-verified on this model/hardware**. |
| `vLLM.max_long_partial_prefills` | 1 | Same. |
| `vLLM.long_prefill_token_threshold` | 0 | Same. |
| `vLLM.dtype` | auto | Model numeric precision — not a goodput lever this study varies. |

**Excluded entirely** (absent from both `parametersSelection` and baseline `values` —
never rendered at all, since the deployment template never references their tokens):

| Parameter | Why |
|---|---|
| `vLLM.spec_method` / `vLLM.spec_tokens` | `1-goodput-realistic-load` hit 5 distinct spec-decoding crashes trying this on the exact same model (Qwen2.5-7B-Instruct) — deliberately not attempted here either. No `--spec-method`/`--spec-tokens` flags in the deployment template at all (not even pinned to a sentinel), same treatment `1-goodput-realistic-load` settled on. |
| `vLLM.prefix_caching_hash_algo` | Prefix caching disabled entirely via a hardcoded `--no-enable-prefix-caching` flag — carried forward from `1-goodput-realistic-load`. |
| `vLLM.compilation_mode` | No direct top-level CLI flag exists for it — same reasoning as prior studies. |

**REMOVED 2026-08-27 (explicit user decision)**: all `parameterConstraints` inherited
from `1-goodput-realistic-load` — `FLASH_ATTN`+`kv_cache_dtype`,
`FlashInfer`+`block_size`, `max_num_batched_tokens`≥`max_num_seqs`, and the 3
`TRITON_ATTN`+fp8 exclusions root-caused as Ampere-specific (see that study's README)
— are all gone from `akamas/2-Larger-Model-G7e.yaml`. The optimizer now explores the
full `parametersSelection` space unconstrained on this hardware (RTX PRO 6000
Blackwell, SM120), including combinations previously excluded either as
Ampere-specific known-bad or as vLLM's own CLI validation rules. Expect more failed
`optimize`-step experiments as a result — invalid combinations now surface as real
vLLM startup errors instead of being pre-excluded; `maxFailedExperiments: 200` has
ample headroom for this. A manual `TRITON_ATTN`+fp8 smoke test that would have answered
the Ampere-vs-SM120 question directly was started 2026-08-27 but abandoned mid-flight
(the pod came up and stayed `Running` before being reverted, an unconfirmed but
promising data point) in favor of this broader unconstrained-search approach instead.

## Prerequisites still open before this study can be started

`akamas/` and `k8s/` are now populated (2026-08-20) — see `akamas/README.md` for the
full resource summary and its own "Placeholders left" section. What's still open:

1. Confirm the installed vLLM optimization pack version and that its parameter domains
   are still valid for whatever vLLM build this model actually requires (see "Stack &
   versions" above) — these resources were built against a scratch clone of pack
   `1.5.1`, not a live `akamas describe optimization-pack vLLM` check.
2. **CHANGED 2026-08-27**: image tag reverted to **`v0.22.0`** (matching
   `0-explorative`/`1-goodput-realistic-load` exactly) along with the model swap back
   to `Qwen2.5-7B-Instruct` — the `v0.27.1` pin was only needed for the abandoned
   `Qwen/Qwen3.8-27B` attempt. **Not yet verified**: `v0.22.0` has never been
   smoke-tested on this GPU's SM120 compute capability — do this before trusting an
   Akamas run, same convention as the two incidents below.
3. Recalibrate the AIPerf concurrency sweep and SLA thresholds against this hardware
   directly (manual exploration, same process as `1-goodput-realistic-load`'s own
   "Sizing the concurrency sweep" section) before trusting the carried-forward numbers
   in `k8s/05-job.yaml`/`akamas/2-Larger-Model-G7e.yaml`'s `windowing` — lower-risk now
   than before the model swap (see "Load generator" above), since the model is no
   longer also different, but still not yet verified on this specific GPU.
4. Supply `akamas/id_rsa` (the `toolbox` host SSH key) — not generated by this scaffold,
   same convention as prior studies' committed keys, see `akamas/README.md`.
5. Validate every `akamas/*.yaml` file against a live Akamas instance (`akamas describe
   optimization-pack vLLM`, then `akamas create -f ...` for real) — only structurally
   validated against a scratch clone of the pack's source so far, not a live CLI (see
   `akamas/README.md` "Validation performed").
6. Sanity-check `attention_backend=FLASHINFER`/`TRITON_ATTN` and each `kv_cache_dtype`
   fp8-family value (`fp8`/`fp8_e4m3`/`fp8_e5m2`) with a manual `vllm serve` smoke test
   on the actual `g7e.4xlarge` node before trusting any `optimize`-step experiment that
   lands on one of them — vLLM's SM120 (RTX PRO 6000 Blackwell) kernel support has
   documented gaps in exactly this area (FP8/FP4 kernel-selection code that sometimes
   silently falls back instead of erroring, FlashInfer JIT breakage on some CUDA
   builds) that don't affect Hopper/H100. Confirm the installed vLLM build's
   CUDA/driver version actually supports this GPU's compute capability (12.0) at all
   before anything else in this list. **Started 2026-08-27** (`TRITON_ATTN`+`fp8`,
   after re-provisioning `vllm-model-cache` into the node's actual AZ, us-east-2b) but
   abandoned mid-flight in favor of the model-swap reset above — resume this test once
   the swapped-back baseline is reverified.
7. ~~Clear the shared AIPerf dataset cache~~ **RESOLVED 2026-08-27**: deleted
   `/benchmarks/sharegpt-cache/inputs.json` from the `aiperf-results` PVC — it had
   `"model": "qwen3-8-27b"` baked in from this study's own 2026-08-25 run, which would
   have 404'd every request against the now-reverted `qwen2.5-7b` the same way the
   reverse mismatch did before (see `k8s/05-job.yaml`'s `CONCURRENCY_LIST` comment).
   The next run's own "if not exists, regenerate" logic will rebuild it correctly.
   Also cleaned up the stale `Qwen/Qwen3.8-27B` weights (~52GB) from
   `vllm-model-cache` — only the current `Qwen2.5-7B-Instruct` (~15GB) remains.

## Incidents found during manual smoke-testing (2026-08-21)

**Historical — pertain to the abandoned `Qwen/Qwen3.8-27B` attempt** (see "Model swap"
above). Kept for the record per this repo's convention of documenting real,
root-caused failures rather than leaving them as mysterious history; incident #2's
`max_num_seqs` pin it required has since been removed from the baseline (the swapped-
back `Qwen2.5-7B-Instruct` doesn't need it). Before creating this study in Akamas,
`vLLM` was deployed by hand against the real `g7e.4xlarge` node (per "How to run"
below's own recommended pre-check) to validate the baseline design.

1. **`--max-num-partial-prefills`/`--max-long-partial-prefills` don't exist on this
   vLLM version** — first manual deploy (image `vllm/vllm-openai:latest`, the
   baseline design at the time pinning all 25 non-`gpu_memory_utilization`
   parameters explicitly via `values`) crashed immediately:
   `vllm: error: unrecognized arguments: --max-num-partial-prefills=1
   --max-long-partial-prefills=1`. Root cause: these two CLI flags, carried forward
   from `0-explorative`/`1-goodput-realistic-load` as "incident avoidance" pins,
   were removed/renamed between vLLM `0.22.0` and whatever version `:latest`
   resolved to — a flag-name-drift risk pinned-`defaultValue` rendering can't
   protect against. **Fixed**: baseline redesigned to match
   `1-goodput-realistic-load`'s `doNotRenderParameters` pattern instead of pinning
   every parameter — an excluded parameter's flag is never rendered at all, so a
   removed flag simply can't crash the baseline.
2. **`max_num_seqs` (vLLM's own auto-selected default, 1024) exceeds available Mamba
   cache blocks (603) at `gpu_memory_utilization=0.90`** — the redesigned "bare"
   baseline (only `gpu_memory_utilization` rendered) still crashed:
   `ValueError: max_num_seqs (1024) exceeds available Mamba cache blocks (603).
   Each decode sequence requires one Mamba cache block, so CUDA graph capture
   cannot proceed. Please lower max_num_seqs to at most 603 or increase
   gpu_memory_utilization.` Root cause: `Qwen/Qwen3.8-27B` is a **hybrid
   Mamba/attention architecture** (GDN — Gated DeltaNet; confirmed in the engine
   log: `Using Triton/FLA GDN prefill kernel`), not the "dense, non-MoE"
   pure-transformer shape this study's README originally assumed by analogy with
   `1-goodput-realistic-load`'s Qwen2.5-7B. Mamba layers need a fixed-size
   recurrent cache block per in-flight sequence, on top of (and constrained
   independently from) the standard KV-cache budget `gpu_memory_utilization`
   controls — so `1-goodput-realistic-load`'s core assumption behind its bare-baseline
   design ("every other parameter at vLLM's own stock default is safe, because
   that's vLLM's most-tested startup path") does not hold for this model's
   architecture. **Fixed**: also pin `vLLM.max_num_seqs: 256` in the baseline's
   `values` (comfortably under the 603-block ceiling vLLM's own error reported) —
   verified end-to-end against the real node: model loads (51.1 GiB, ~7-30s once
   cached on the PVC), engine initializes, `/health` returns 200, and a real
   `/v1/chat/completions` request completes successfully.
   - **Consequence for the `optimize` step**: this Mamba-cache ceiling is a real
     constraint the optimizer will hit during actual experiments too — expected and
     left unconstrained deliberately (no new `parameterConstraints` entry added),
     since the exact ceiling depends on `gpu_memory_utilization`'s own tuned value
     and isn't a fixed number the way the `TRITON_ATTN`+fp8 exclusions are. Watch
     `optimize`-step failures for this exact `ValueError` — if it dominates failed
     experiments, revisit whether a `parameterConstraints` formula approximating the
     `max_num_seqs`/`gpu_memory_utilization` relationship is worth adding.

## How to run

See `infra/README.md` for the cluster-provisioning flow — this study reuses the
existing `vllm-bench` cluster and adds a new GPU node group (`g7e.4xlarge`, RTX PRO
6000 Blackwell — see "Hardware swap" above). Once the cluster,
monitoring stack, and prerequisites above are confirmed, see `akamas/README.md`'s
"Setup & run" section for the full command sequence:

```bash
akamas describe optimization-pack vLLM   # confirm pack version (see Prerequisites)

akamas create -f studies/2-larger-model-g7e/akamas/
akamas start study "2-Larger-Model-G7e"
```

## Results

<Filled in by the study-recap skill once the study finishes.>

## Conclusions

<Filled in by the study-recap skill once the study finishes.>
