# 2-Larger-Model-G7e

**Status:** TODO
**Dates:** —

## Objective

Same goodput question as `1-goodput-realistic-load` — maximize
`vLLM.prefill_token_throughput + vLLM.decode_token_throughput` subject to a P95 TTFT
and P95 ITL latency SLA (`goal.constraints`) — but scaled to a **~4x larger model on a
single, higher-VRAM GPU**: does goodput scale favorably when the model gets bigger and
the GPU has much more memory to work with, or does the larger model's own latency cost
(and, on this study's actual hardware, a materially lower memory bandwidth than H100 —
see "Hardware swap" below) eat into whatever headroom the extra VRAM provides? Not
derivable from `0-explorative` or `1-goodput-realistic-load` alone, both of which are
Qwen2.5-7B-Instruct on a single A10G.

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
throughput at parity of hardware). This study asks a different question instead (a
bigger model, not more GPUs), so it doesn't fit Goal A/B's original framing cleanly.
**The original Study #2 plan is kept as a superseded historical record in
`ROADMAP.md` Section D** — not deleted — because Section D's Study #3/#4 both build on
its `p5.48xlarge`/Qwen2.5-7B baseline for their own tensor-parallelism scaling
questions; see `ROADMAP.md`'s explicit flag on those two sections for the
reconciliation this redirect now leaves open. This study's own scope stops at "does a
bigger model on a single, more powerful GPU improve goodput" — it does not attempt to
answer Goal A/B's multi-GPU right-sizing questions.

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
- **Workload under test:** `Qwen/Qwen3.8-27B` (dense, 27.8B parameters — **not** MoE
  despite the "3.8" name, which is a version number, not an active-parameter count;
  released 2026-08-14, day-0 vLLM support announced by the vLLM project itself).
  Multimodal checkpoint (native vision + text) but served **text-only** for this
  benchmark — no image/video inputs are sent, so the vision encoder should sit idle;
  flagged here in case it turns out to add measurable startup/memory overhead even
  unused. Served as `qwen3-8-27b`, namespace `llm-serving`.
  - **RESOLVED 2026-08-21 (image tag)**: needs a vLLM build newer than the `v0.22.0`
    image pinned in `0-explorative`/`1-goodput-realistic-load` — confirmed by a real
    manual deploy, resolved to **`vllm/vllm-openai:v0.27.1`**, now pinned in
    `k8s/01-deployment_template.yaml` (see "Prerequisites still open" #2). **Still
    open**: whether the installed vLLM optimization pack's parameter set (built
    against `0.22.0`) still applies cleanly to `0.27.1` has not been verified against
    a live Akamas instance yet — same open question as `1-goodput-realistic-load`'s
    own pack-version prerequisite, now sharpened to a concrete version jump
    (`0.22.0` → `0.27.1`, 5 minor versions) rather than an unknown target.
  - Ships an MTP (multi-token prediction) draft head **built into the checkpoint**
    (speculative decoding needs no separate draft model) — **deliberately pinned off**
    for this study (see "Parameters tuned" below), not tuned. `1-goodput-realistic-load`
    hit 5 distinct crashes across its `optimize` step trying `spec_method`/`spec_tokens`
    on Qwen2.5-7B; revisit speculative decoding for this model only after this study's
    baseline is proven stable, not from the start.
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
- **Load generator:** **TODO, carried forward as an explicit starting point, not yet
  recalibrated** — same tool and methodology as `1-goodput-realistic-load`: NVIDIA
  AIPerf, `--public-dataset sharegpt` (real ShareGPT replay), closed-loop concurrency
  sweep, `windowing.stability`. That study's *current* concurrency list
  (`150,179,213,253,302,359,428,509,606,722,860,1024`, 12 levels, 300s each) and SLA
  thresholds (TTFT P95 ≤ 1500ms, ITL P95 ≤ 300ms) were calibrated specifically for
  Qwen2.5-7B-Instruct on an A10G — see that study's own README, "Sizing the
  concurrency sweep," for the full multi-week calibration process this had to go
  through. **Those exact numbers almost certainly don't transfer** to a ~4x larger
  model on different single-GPU hardware (the true saturation point could land lower —
  a bigger model's per-token cost is higher, and this study's actual GPU, RTX PRO 6000
  Blackwell, has roughly half H100's memory bandwidth — or higher — 96GB vs 80GB VRAM
  gives more KV-cache headroom — no prior data points either way for this specific
  pairing). Before
  this study's real `optimize` step runs, repeat that study's own manual-sweep
  calibration process against this model/hardware directly rather than trusting the
  carried-forward numbers.
- **Telemetry:** Prometheus, same instance/metric catalog as prior studies
  (`kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`,
  `duration: 30`, `logLevel: DETAILED`) — reused as-is since telemetry reads vLLM's own
  `/metrics`, independent of model/hardware. Per `ROADMAP.md` Q7, this repo's telemetry
  config has never been independently re-verified against a live vLLM `/metrics`
  endpoint — worth doing once for this study too, not assumed inherited-and-correct.

## Parameters tuned

The same 14 tunable parameters as `1-goodput-realistic-load` (see that study's README
for the full per-parameter rationale, largely hardware-independent), now built into
`akamas/2-Larger-Model-G7e.yaml`. **Baseline design (corrected 2026-08-21, see
"Incidents" below) matches `1-goodput-realistic-load`'s `doNotRenderParameters`
pattern, with one model-specific addition**: every tuned/pinned parameter referenced
by the deployment template is excluded from baseline rendering (so vLLM applies its
own real default) *except* two — `gpu_memory_utilization` (pinned to 0.90, since the
pack's own `defaultValue` of 0.92 doesn't match what this baseline wants) and
`max_num_seqs` (pinned to 256, needed *only* for this model — `Qwen/Qwen3.8-27B`'s
hybrid Mamba/attention architecture makes vLLM's own auto-selected default for it
unsafe here, see incident #2 below; `1-goodput-realistic-load` itself doesn't need
this exception for Qwen2.5-7B's pure-transformer shape). The "Baseline" column below
shows the pack's own `defaultValue` for reference, not what actually renders — every
row except the two just named is left unrendered at baseline (`doNotRenderParameters`)
and only takes its shown value during `optimize`, when Akamas' `parametersSelection`
search picks a real value for it.

| Parameter | Domain / categories | Baseline (rendered) |
|---|---|---|
| `vLLM.gpu_memory_utilization` | [0.85, 0.95] | **0.90** (pinned) |
| `vLLM.max_num_seqs` | [16, 1024] | **256** (pinned, see incident #2) |
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
| `vLLM.enable_expert_parallel` | false | Qwen3.8-27B is dense, not MoE. |
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
| `vLLM.spec_method` / `vLLM.spec_tokens` | Qwen3.8-27B ships an MTP draft head, but `1-goodput-realistic-load` hit 5 distinct spec-decoding crashes on a different model — deliberately not attempted until this study's own baseline is proven stable. No `--spec-method`/`--spec-tokens` flags in the deployment template at all (not even pinned to a sentinel), same treatment `1-goodput-realistic-load` settled on. |
| `vLLM.prefix_caching_hash_algo` | Prefix caching disabled entirely via a hardcoded `--no-enable-prefix-caching` flag — carried forward from `1-goodput-realistic-load`. |
| `vLLM.compilation_mode` | No direct top-level CLI flag exists for it — same reasoning as prior studies. |

**TODO**: re-verify the `TRITON_ATTN`+fp8 `parameterConstraints` inherited from
`1-goodput-realistic-load` — those were root-caused as Ampere-specific (see that
study's README). This study's actual GPU (RTX PRO 6000 Blackwell, SM120) is neither
Ampere nor Hopper — don't assume H100's "native FP8, exclusion unneeded" reasoning
transfers here either; SM120 has its own documented FP8/FP4 kernel-selection rough
edges upstream. Confirm empirically whether those exclusions are still needed here
rather than assuming they transfer, or assuming they're safe to drop. Flagged
explicitly (as a YAML comment) in `akamas/2-Larger-Model-G7e.yaml` itself, not just
here.

## Prerequisites still open before this study can be started

`akamas/` and `k8s/` are now populated (2026-08-20) — see `akamas/README.md` for the
full resource summary and its own "Placeholders left" section. What's still open:

1. Confirm the installed vLLM optimization pack version and that its parameter domains
   are still valid for whatever vLLM build this model actually requires (see "Stack &
   versions" above) — these resources were built against a scratch clone of pack
   `1.5.1`, not a live `akamas describe optimization-pack vLLM` check.
2. ~~Confirm the exact `vllm/vllm-openai` image tag~~ **RESOLVED 2026-08-21**: `v0.22.0`
   (pinned in prior studies) does not support `Qwen/Qwen3.8-27B`, confirmed by
   deploying `:latest` for real against this study's own `g7e.4xlarge` node —
   resolved to **vLLM 0.27.1**, image digest verified identical to the
   `vllm/vllm-openai:v0.27.1` tag on Docker Hub. `k8s/01-deployment_template.yaml`
   now pins that exact tag instead of floating on `:latest`.
3. Recalibrate the AIPerf concurrency sweep and SLA thresholds against this
   model/hardware directly (manual exploration, same process as
   `1-goodput-realistic-load`'s own "Sizing the concurrency sweep" section) before
   trusting the carried-forward numbers in `k8s/05-job.yaml`/`akamas/2-Larger-Model-G7e.yaml`'s
   `windowing`.
4. Supply `akamas/id_rsa` (the `toolbox` host SSH key) — not generated by this scaffold,
   same convention as prior studies' committed keys, see `akamas/README.md`.
5. Validate every `akamas/*.yaml` file against a live Akamas instance (`akamas describe
   optimization-pack vLLM`, then `akamas create -f ...` for real) — only structurally
   validated against a scratch clone of the pack's source so far, not a live CLI (see
   `akamas/README.md` "Validation performed").
6. **New, 2026-08-21**: sanity-check `attention_backend=FLASHINFER` and each
   `kv_cache_dtype` fp8-family value (`fp8`/`fp8_e4m3`/`fp8_e5m2`) with a manual `vllm
   serve` smoke test on the actual `g7e.4xlarge` node before trusting any
   `optimize`-step experiment that lands on one of them — vLLM's SM120 (RTX PRO 6000
   Blackwell) kernel support has documented gaps in exactly this area (FP8/FP4
   kernel-selection code that sometimes silently falls back instead of erroring,
   FlashInfer JIT breakage on some CUDA builds) that don't affect Hopper/H100. Confirm
   the installed vLLM build's CUDA/driver version actually supports this GPU's compute
   capability (12.0) at all before anything else in this list.

## Incidents found during manual smoke-testing (2026-08-21)

Before creating this study in Akamas, `vLLM` was deployed by hand against the real
`g7e.4xlarge` node (per "How to run" below's own recommended pre-check) to validate the
baseline design — same convention `0-explorative`/`1-goodput-realistic-load` use for
documenting real, root-caused failures rather than leaving them as mysterious history.
Both incidents below are now fixed in `akamas/2-Larger-Model-G7e.yaml`'s baseline step.

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
