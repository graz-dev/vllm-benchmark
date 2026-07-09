<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# AI Systems Performance Engineering — Multinode Parallelism, Disaggregated Prefill/Decode, and Advanced KV Cache Tuning

**Source:** Chris Fregly, *AI Systems Performance Engineering* (O'Reilly, Nov 2025) —
Chapter 15 "Multinode Inference, Parallelism, Decoding, and Routing Optimizations",
Chapter 17 "Scaling Disaggregated Prefill and Decode for Inference", Chapter 18
"Advanced Prefill-Decode and KV Cache Tuning". Local copy:
`knowledge/sources/AI Systems Performance Engineering.pdf`.
**Date distilled:** 2026-07-08

## Problem addressed

These three chapters form one continuous architectural narrative for scaling LLM
inference beyond a single vLLM replica: how to disaggregate the prefill phase
(compute-bound, parallel) from the decode phase (memory-bandwidth-bound, sequential),
how to pick a parallelism strategy (tensor/pipeline/expert/data/context) per phase and
per model shape, how to accelerate the sequential decode bottleneck (speculative
decoding), how to route MoE tokens and disaggregated requests, and how to size and
transfer the KV cache across nodes with near-zero overhead. This repo's studies so far
are all single-instance, non-disaggregated vLLM — so most of this note is **forward-looking
architecture knowledge for a future multinode/MoE study**, not something applicable to
today's baseline study. Treat it as a reference to pull from once backlog work moves
past single-replica tuning, and as scoping input (KV-cache sizing math) usable even now.

## Levers / parameters touched

- **Parallelism degree per axis**: tensor (`TP`), pipeline (`PP`), expert (`EP`), data
  (`DP`), context/sequence (`CP`/`SP`) — and critically, **different degrees per phase**
  (e.g. `TP_p=2, PP_p=2` for prefill vs. `TP_d=1..N` for decode), not one global setting.
- **Prefill/decode disaggregation topology**: worker counts per phase, GPU type per
  phase (heterogeneous hardware), KV-transfer connector (NIXL push/pull/IPC/queue),
  routing policy (round robin, least-requests, prefix-aware, KV-aware).
- **Speculative decoding method + config**: draft-model choice/size, verification mode
  (greedy/nucleus/tree), method family (2-model draft, EAGLE/EAGLE-2/EAGLE-3,
  self-speculative, Medusa).
- **MoE routing**: capacity factor (overflow cap per expert per batch), top-k gating,
  expert replication, hierarchical/async all-to-all scheduling.
- **KV cache**: dtype/precision (FP16/FP8/FP4), page/block size (8/16/32/64/128 tokens
  — vLLM defaults to 16), disaggregated pool tiering (GPU HBM → CPU DRAM → NVMe),
  prefix-cache reuse (exact-match, hash-based, 16-token block granularity in vLLM).
- **QoS/admission control**: early-rejection thresholds, priority/tier reserved-capacity
  fractions, adaptive generation-length limits under load.
- **vLLM-specific flags named**: `--max-seq-len-to-capture` (CUDA graph capture length,
  default 8192 — controls graph coverage, *not* runtime batch size),
  `--max-num-seqs`/`--max-num-batched-tokens` (already-modeled parameters — this is what
  actually bounds runtime batching), `enable_prefix_caching`.

## Key results

All numbers below are **condition-specific** — the hardware/model/workload they were
measured under is included; don't transplant a number without its condition.

- **DistServe**: eliminating prefill/decode interference via disaggregation → up to
  **7.4× more goodput** within simultaneous TTFT+TPOT SLO constraints (up to 12.6×
  tighter SLOs), vs. a colocated SOTA baseline.
- **DistServe worked example** (colocated vs. 2P1D, SLO p90 TTFT ≤400ms / p90 TPOT
  ≤40ms): colocated goodput = 1.6 RPS/GPU (bounded by decode's TPOT limit); 2-prefill +
  1-decode-GPU disaggregated = **3.3 RPS/GPU** — a **~2× goodput gain at ~3× hardware
  cost**. The book itself flags this as needing further cost-effectiveness tuning, not a
  free win — record this trade-off explicitly if a future study reproduces it.
- **MLPerf v5.0 (2025) SLO targets** (useful as realistic SLO anchors for a future
  study's `goal.yaml`): Llama2 70B — p99 TTFT ~450ms, p99 TPOT ~40ms; Llama 3.1 405B —
  p99 TTFT ~6s, p99 TPOT ~175ms.
- **Heterogeneous hardware for PD (Splitwise study)**: 4×H100 (prefill) + 4×A100
  (decode), 8-GPU mixed cluster vs. 8-GPU homogeneous baseline at matched cost/power →
  **2.35× more throughput**; a cost-optimized configuration gave **1.4× throughput at
  20% lower cost**. KV transfer over NVSwitch between *different* GPU generations
  incurred minimal overhead.
- **HexGen-2** (automated heterogeneous PD scheduler, Llama 2 70B): up to **2× serving
  throughput** (~1.3× average) vs. SOTA systems at the same price point, or matched
  throughput at **~30% lower cost**.
- **Parallelism choice per phase** (Table 18-1/18-2 example): prefill favors pipeline
  parallelism (lower all-reduce overhead, larger token count amortizes PP bubbles);
  decode favors tensor parallelism or `TP=1` (avoids PP bubbles on single-token steps;
  higher TP only helps for tiny-GEMM/small-batch cases or when the model doesn't fit on
  one GPU). Caveat stated explicitly: the right choice depends on network
  bandwidth/collective latency/model shape — this is a starting heuristic, not a rule.
- **Speculative decoding speedups** (each condition-specific — see also
  `knowledge/notes/2026-07-speculative-decoding-survey.md` and
  `knowledge/notes/2026-07-distributed-inference-advanced-deployment-patterns.md` for
  overlapping/complementary numbers): 2-model draft ~1.5–2.5× practical; **EAGLE** up to
  ~3.5×; **EAGLE-2** 20–40% faster than EAGLE-1; **EAGLE-3** up to 1.4× over EAGLE-2, up
  to 6.5× over an unoptimized baseline; **Medusa** ~2.2–3.6×; single-model
  self-speculative ~2×; "consistent decoding" ~3×.
- **MoE capacity factor**: production systems commonly use **1.2–1.5** (20–50% overflow
  allowance) with top-2 gating to bound hot-expert overload without starving throughput.
- **KV cache size formula**: `bytes_per_token = 2 × n_layers × n_kv_heads × head_dim ×
  bytes_per_element`. Worked examples: a 13B-class model (40 layers, 40 heads, head_dim
  128, FP16, MHA) → ~0.819 MB/token (~3.36 GB for a 4096-token context; ~1.68 GB at
  FP8); the same model with GQA (8 kv-heads) → ~0.671 GB/4096 tokens at FP16 (~0.336 GB
  FP8); with MQA (1 kv-head) → ~0.084 GB at FP16. A 70B model (80 layers, 32 heads,
  head_dim 128) at a **250,000-token context**: ~1.31 MB/token → **~328 GB total KV**
  at FP16 — reducible to roughly **100–150 GB** with FP8 + selective-layer caching, but
  still likely exceeding a single GPU.
- **KV transfer overhead reduction via page collation** (LMCache, RDMA/NIXL): naive
  small-page transfer of a 7,500-token KV cache (470 small transfers) = **20ms**;
  collating into ≥128-token pages = **~8ms**. General guidance: modern engines support
  8/16/32/64/128-token pages; vLLM's PagedAttention default is 16 tokens/block — collate
  before RDMA for disaggregated setups.
- **POD-Attention** (SM-aware CTA scheduling colocating prefill+decode work on the same
  SMs): up to **~29%** attention-performance improvement.
- **ThunderMLA** (fused decode "megakernel" building on FlashMLA): **20–35% faster
  decode throughput** than FlashMLA across workloads (DeepSeek MLA-style models).
- **Arrow** (adaptive prefill/decode instance-role scaling): up to **5.6× higher request
  serving rate** vs. a non-adaptive/static system, under an extreme workload-shift
  scenario; smaller-but-still-significant gains typical.

## Implications for vLLM/k8s tuning

- **Nothing here is directly actionable for this repo's current single-instance,
  non-disaggregated studies** — no installed pack models PD disaggregation, EP/PP/CP, or
  speculative decoding (confirmed against this repo's own tracking at the time; re-check
  with `akamas describe optimization-pack vLLM` or the pack's own repo,
  https://gitlab.com/akamas/optimization-packs/vllm). This note's value is
  as a reference for a *future* multinode/MoE/disaggregation study, and as reinforcement
  for prioritizing pack-gap requests already logged.
- **KV cache size formula is usable today, independent of any pack gap**: before
  choosing a `max_model_len`/`gpu_memory_utilization` domain for *any* study (including
  today's single-replica ones), compute the expected KV-cache-per-token footprint for
  the actual model/hardware to sanity-check that a proposed domain is even
  memory-feasible, rather than discovering infeasibility mid-experiment via OOM/
  preemption. This is a scoping tool, not a new hypothesis.
- **H5's "TP is a minimum-that-fits, not a free sweep" already in `ROADMAP.md`** is
  reinforced and sharpened here: prefill and decode want *different* parallelism choices
  (PP for prefill, TP=1/low-TP for decode) — if this repo ever models a disaggregated
  topology, `tensor_parallel_size` (or its future pipeline/expert-parallel
  counterparts) would need to be tunable *per phase*, not once per component.
- **Speculative decoding prioritization** (already flagged in `ROADMAP.md`'s pack-request
  debt item, sourced from the advanced-deployment-patterns note and the speculative
  decoding survey) gets additional concrete numbers here (EAGLE-2/3 ranges, Medusa) —
  no new ask, just more evidence for the existing ask's priority.
- **MoE capacity-factor guidance (1.2–1.5)** is new, concrete detail — relevant only if a
  future study targets a MoE model; not applicable to this repo's dense-model studies so
  far.

## Which Akamas parameters to explore

No new parameter requests beyond what's already logged in `ROADMAP.md`'s "Pack request"
debt item (`pipeline_parallel_size`, expert-parallelism/EPLB, decode/prefill context
parallelism, disaggregation topology, speculative-decoding config, KV cache
dtype/quantization, KV-transfer connector selection, KV-cache preemption-threshold,
`swap_space`, `max_seq_len_to_capture`, `dtype`, `enforce_eager`, `scheduling_policy`,
`scheduler_delay_factor`, `data_parallel_size` — all already listed). One new candidate
this source surfaces, low priority until a disaggregation/multinode study is scoped:

- **KV cache page/block size** (vLLM's `--block-size`, default 16 tokens) — not
  confirmed in this repo's tracked vLLM parameter summary at the time. Matters
  specifically for disaggregated KV-transfer efficiency
  (16-token vs. ≥128-token pages: 20ms→8ms in the LMCache example above); irrelevant to
  a non-disaggregated single-replica study, so not worth raising with the pack owner
  until a disaggregation study is actually being scoped.
