# 2-Larger-Model-H100

**Status:** TODO
**Dates:** —

## Objective

Same goodput question as `1-goodput-realistic-load` — maximize
`vLLM.prefill_token_throughput + vLLM.decode_token_throughput` subject to a P95 TTFT
and P95 ITL latency SLA (`goal.constraints`) — but scaled to a **~4x larger model on
much more capable single-GPU hardware**: does goodput scale favorably when both the
model and the GPU generation move up together, or does the larger model's own latency
cost eat into the H100's extra throughput headroom? Not derivable from `0-explorative`
or `1-goodput-realistic-load` alone, both of which are Qwen2.5-7B-Instruct on a single
A10G.

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
  `akamas/2-Larger-Model-H100.yaml` and its components were built against a scratch
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
  - **TODO, open prerequisite**: this model needs `transformers>=5.8.0` and a vLLM
    build newer than the `v0.22.0` image pinned in `0-explorative`/
    `1-goodput-realistic-load` — neither the exact `vllm/vllm-openai` tag nor whether
    the installed vLLM optimization pack's parameter set (built against `0.22.0`) still
    applies cleanly to whatever newer vLLM version this model needs has been verified
    against a live Akamas instance yet, the same way `1-goodput-realistic-load`'s own
    README flagged its pack-version prerequisite.
  - Ships an MTP (multi-token prediction) draft head **built into the checkpoint**
    (speculative decoding needs no separate draft model) — **deliberately pinned off**
    for this study (see "Parameters tuned" below), not tuned. `1-goodput-realistic-load`
    hit 5 distinct crashes across its `optimize` step trying `spec_method`/`spec_tokens`
    on Qwen2.5-7B; revisit speculative decoding for this model only after this study's
    baseline is proven stable, not from the start.
- **Cluster / hardware:** single NVIDIA H100 80GB GPU via AWS **`p5.4xlarge`** (16
  vCPU, 256GiB RAM — confirmed 2026-08-20 via AWS's own P5-single-GPU announcement,
  **not** the 8-GPU `p5.48xlarge` the original Study #2 plan used). **Deliberately
  reuses the same `vllm-bench` EKS cluster** as `0-explorative`/`1-goodput-realistic-load`
  (explicit user decision, 2026-08-20) via a **new, separate managed node group**
  (`llm-serving-h100`) rather than a standalone cluster — see `infra/README.md`. This
  study still keeps its own full `infra/` copy per this repo's atomic-per-study
  convention, but `infra/eks/provision.sh` detects the cluster already exists and adds
  only the missing H100 node group, leaving the existing `system`/`akamas`/`llm-serving`
  (A10G) node groups untouched. **The A10G `llm-serving` node group is currently scaled
  to 0** (2026-08-20) — so there's no live scheduling conflict either way — but the vLLM
  Deployment's `nodeSelector`/`tolerations` (see `k8s/01-deployment_template.yaml`)
  explicitly target `llm-serving-h100` regardless; placement doesn't rely on the other
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
  model on a materially faster GPU (the true saturation point could land lower — a
  bigger model's per-token cost is higher — or higher — H100 is a full GPU generation
  ahead of A10G — no prior data points either way for this specific pairing). Before
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
`akamas/2-Larger-Model-H100.yaml`. **Baseline design differs from that study**: rather
than its elaborate 29-parameter `doNotRenderParameters` exclusion, this study's baseline
pins every referenced parameter explicitly via `values` — the 14 tuned ones below at the
vLLM pack's own declared `defaultValue` (except `gpu_memory_utilization`, pinned to 0.90
same as before), so every value below is actually rendered at baseline, not excluded.

| Parameter | Domain / categories | Baseline |
|---|---|---|
| `vLLM.gpu_memory_utilization` | [0.85, 0.95] | 0.90 |
| `vLLM.max_num_seqs` | [16, 1024] | 128 |
| `vLLM.max_num_batched_tokens` | [256, 8192] | 2048 |
| `vLLM.kv_cache_dtype` | auto, fp8, fp8_e4m3, fp8_e5m2 | auto |
| `vLLM.performance_mode` | balanced, interactivity, throughput | balanced |
| `vLLM.optimization_level` | [0, 3] | 2 |
| `vLLM.enforce_eager` | true, false | false |
| `vLLM.scheduling_policy` | fcfs, priority | fcfs |
| `vLLM.disable_cascade_attn` | true, false | true |
| `vLLM.tokenizer_mode` | auto, hf, slow | auto |
| `vLLM.async_scheduling` | true, false | true |
| `vLLM.max_cudagraph_capture_size` | [1, 1024] | 256 |
| `vLLM.block_size` | 16, 32, 48, 64, 80, 96, 112, 128 (ordinal) | 16 |
| `vLLM.attention_backend` | FLASH_ATTN, FLASHINFER, TRITON_ATTN | FLASH_ATTN |

**Pinned** (not in `parametersSelection`, fixed via baseline `values` — same 12 as
`1-goodput-realistic-load` except `spec_method`/`spec_tokens`, see "Excluded" below):

| Parameter | Value | Why |
|---|---|---|
| `vLLM.tensor_parallel_size` | 1 | Single GPU (`p5.4xlarge` has exactly one H100). |
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
study's README). H100 is Hopper and has native FP8 Tensor Core support; confirm
empirically whether those exclusions are still needed here rather than assuming they
transfer, or assuming they're safe to drop. Flagged explicitly (as a YAML comment) in
`akamas/2-Larger-Model-H100.yaml` itself, not just here.

## Prerequisites still open before this study can be started

`akamas/` and `k8s/` are now populated (2026-08-20) — see `akamas/README.md` for the
full resource summary and its own "Placeholders left" section. What's still open:

1. Confirm the installed vLLM optimization pack version and that its parameter domains
   are still valid for whatever vLLM build this model actually requires (see "Stack &
   versions" above) — these resources were built against a scratch clone of pack
   `1.5.1`, not a live `akamas describe optimization-pack vLLM` check.
2. Confirm the exact `vllm/vllm-openai` image tag (or custom build) that supports
   `Qwen/Qwen3.8-27B` — `v0.22.0` almost certainly does not, and
   `k8s/01-deployment_template.yaml` currently has `:latest` as a functional but
   unpinned placeholder.
3. Recalibrate the AIPerf concurrency sweep and SLA thresholds against this
   model/hardware directly (manual exploration, same process as
   `1-goodput-realistic-load`'s own "Sizing the concurrency sweep" section) before
   trusting the carried-forward numbers in `k8s/05-job.yaml`/`akamas/2-Larger-Model-H100.yaml`'s
   `windowing`.
4. Supply `akamas/id_rsa` (the `toolbox` host SSH key) — not generated by this scaffold,
   same convention as prior studies' committed keys, see `akamas/README.md`.
5. Validate every `akamas/*.yaml` file against a live Akamas instance (`akamas describe
   optimization-pack vLLM`, then `akamas create -f ...` for real) — only structurally
   validated against a scratch clone of the pack's source so far, not a live CLI (see
   `akamas/README.md` "Validation performed").

## How to run

See `infra/README.md` for the cluster-provisioning flow — this study reuses the
existing `vllm-bench` cluster and adds a new H100 node group. Once the cluster,
monitoring stack, and prerequisites above are confirmed, see `akamas/README.md`'s
"Setup & run" section for the full command sequence:

```bash
akamas describe optimization-pack vLLM   # confirm pack version (see Prerequisites)

akamas create -f studies/2-larger-model-h100/akamas/
akamas start study "2-Larger-Model-H100"
```

## Results

<Filled in by the study-recap skill once the study finishes.>

## Conclusions

<Filled in by the study-recap skill once the study finishes.>
