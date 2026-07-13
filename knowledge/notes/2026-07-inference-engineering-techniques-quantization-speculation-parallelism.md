<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Inference Engineering — Quantization, Speculative Decoding, Caching, Parallelism, Disaggregation

**Source:** *Inference Engineering* by Philip Kiely (Baseten Books, 2026), Chapter 5
"Techniques" (`knowledge/sources/Inference Engineering.pdf`, printed pages 117-151).
**Date distilled:** 2026-07-13

## Problem addressed

The chapter most directly aligned with this knowledge base's parameter-tuning category:
a systematic treatment of the five acceleration techniques whose knobs this repo's
studies already touch or have flagged as pack-request gaps — quantization
(`kv_cache_dtype`), speculative decoding (flagged pack-request), caching (prefix-cache
behavior, `block_size`), model parallelism (`tensor_parallel_size`, H5/H6), and
disaggregation (llm-d/Dynamo notes already tracked).

## Levers / parameters touched

Quantization precision/component selection (weights/activations/KV-cache/attention,
each independently quantizable), speculative decoding algorithm choice (draft-target vs.
Medusa vs. EAGLE vs. n-gram/Lookahead) and draft sequence length, KV-cache storage tier
and prefix-cache/cache-aware-routing configuration, model-parallelism degree and split
(`tensor_parallel_size`/pipeline/expert parallelism), and disaggregation topology
(xPyD prefill:decode engine ratio).

## Key results

- **Quantization performance/risk, quantified**: cutting precision one level typically
  yields **30-50% better performance** (not a clean 2x, due to quantization overhead).
  Component sensitivity ranking, least to most risky: **weights** (least sensitive,
  linear layers) → **activations** (only somewhat sensitive) → **KV cache** (moderately
  sensitive — but errors compound token-to-token since the KV cache is reused by every
  subsequent token) → **attention** (most sensitive, softmax-heavy, almost never
  quantized even in aggressive schemes). A production-quality quantization target is
  **zero perceptible quality loss**, verified via three complementary checks: perplexity
  (cheapest), a public intelligence benchmark (MMLU/SWE-bench), and a custom/domain
  eval — comparing all three against the unquantized baseline, not just one.
- **Number format landscape**: FP8/MXFP8 is "the sweet spot for improving performance
  without sacrificing quality" for most production use; FP4/NVFP4 is promising
  (NVFP4's finer block size of 16 + secondary 32-bit global scale factor specifically
  targets the quality loss 4-bit formats otherwise introduce) but newer/less proven;
  integer formats (INT8/INT4) are explicitly **not recommended** for quality-sensitive
  production workloads due to lacking a dynamic-range exponent — floating-point formats
  are preferred whenever precision matters. **Directly explains this repo's own
  `0-explorative` result**: `FLASHINFER` + `kv_cache_dtype=fp8_e4m3` won as the best
  configuration — fp8 quantization is exactly the "sweet spot," and it was applied only
  to the KV cache (moderate-risk component), not to attention itself — consistent with
  this chapter's own risk-graduated guidance, not a coincidence.
- **Speculative decoding, sharper operational nuance than previously captured**: works
  because decode is memory-bound with idle spare compute at low-to-moderate batch sizes
  — draft tokens exploit that idle compute. **Critical, previously-under-emphasized
  point: speculative decoding must be *dynamically disabled* at higher batch sizes**,
  because compute saturates and there's no longer spare capacity to afford draft
  verification — this sharpens (with an operational mechanism, not just an outcome) the
  existing note that speculative decoding's gain "shrinks or inverts at large batch
  sizes." Algorithm comparison: **draft-target** (separate small model, ≥10x smaller by
  parameter count as a rule of thumb, easiest to set up with no training, but highest
  overhead — dedicates GPU memory/compute to a whole second model); **Medusa** (extra
  decoder heads on the target model, historically important but "not widely used in
  production today"); **EAGLE** (purpose-built draft model trained on the target
  model's own hidden states from early/middle/late layers, generates up to 8 draft
  tokens with high acceptance, "the go-to speculation algorithm for general use," single
  unified PyTorch module avoiding draft/target CPU round-trips); **n-gram
  speculation/Lookahead Decoding** (no draft model at all — an n-gram dictionary built
  during prefill/decode; can exceed 10 draft tokens, but only when generated content
  closely mirrors the input — "outperforms EAGLE" specifically for **code completion/
  revision**, generalizes poorly outside high-repetition domains). Token acceptance rate
  degrades with sequence position and rises with lower temperature.
- **KV cache storage tiers, a concrete 4-level hierarchy** not previously this granular
  in this knowledge base: G1 device VRAM (TBps, 10s-100s GB), G2 host CPU RAM (10s-100s
  GB/s, 100s GB-TBs), G3 local SSD (5-10 GB/s, TBs), G4 networked SSD (GBps, 10s of TBs)
  — NVIDIA Dynamo's KVBM (KV Block Manager) automates moving blocks between tiers by
  recency. Cache-aware routing (sticky-session-style routing to the replica already
  holding a conversation's KV cache) is distinct from prefix caching itself and needed
  once there are multiple replicas — a global (G4) KV cache across replicas trades some
  latency for surviving replica cycling during autoscaling. **Prefix caching mechanic,
  precisely stated**: the cached prefix ends at the *first* token that differs between
  two sequences — reordering a prompt so novel/varying tokens come *late* (not early)
  is what determines whether prefix caching actually saves anything, a context-
  engineering lever independent of any inference-engine flag.
- **Model parallelism — concrete GPU-count sizing formula and a firm default**:
  `vram_required = (bits_precision / 8) × params_billions × kv_cache_allocation_factor`
  (worked example: DeepSeek-V3.1, 671B params, FP8, KV-cache-allocation factor 1.8 →
  ~1200GB VRAM needed → round up to 8×B200 = 1440GB). **Tensor Parallelism is the
  explicit default recommendation for multi-GPU inference** ("should be your default
  strategy"), supporting both dense and MoE models, best for single-node low latency;
  **Pipeline Parallelism** is "not recommended" on its own due to step-by-step pipeline
  latency/utilization loss, used only in combination for multi-node dense models
  (TP8PP2 pattern: TP within a node, PP across nodes); **Expert Parallelism** (MoE-only)
  has markedly lower inter-GPU communication overhead than TP (only routing token→expert
  assignments, not collecting per-layer outputs), making it the better choice at
  multi-node scale for MoE models (EP16) where TP would be communication-bound. Firm
  general guidance: **"unless your model and KV cache are so large as to require
  multi-node inference, it probably isn't the best use of extra hardware — better off
  scaling replicas horizontally, or disaggregating."**
- **Disaggregation — concrete, quantified adoption thresholds** (previously only
  vaguely stated as "large scale" in existing notes): reach for disaggregation only when
  **all three** hold — (1) serving **100M to 1B+ tokens/day** (scale-dependent on model
  size), (2) serving a model of **at least ~100B parameters**, (3) traffic is
  **prefill-heavy with long input sequences**. If (1) or (2) fails, disaggregation wastes
  hardware for minimal gain; if (3) fails, horizontal replica scaling or prefix-cache
  hits serve short-sequence traffic more efficiently than a dedicated prefill fleet.
  NVIDIA Dynamo's **xPyD notation** (e.g. "5P3D" = 5 prefill + 3 decode engines) names
  the actual configurable ratio; **conditional disaggregation** (decode engine handles
  prefill locally if the input is already cached or short) avoids paying disaggregation's
  transfer overhead on cheap requests. New bottleneck introduced by disaggregation
  itself: **prefill queue size** — must be actively managed via thresholds and runtime
  xPyD reconfiguration, or requests queue up waiting for saturated prefill workers.

## Implications for vLLM/k8s tuning

- **Sharpens the disaggregation/Dynamo conditionality already in `ROADMAP.md`'s Q6/
  backlog #4 discussion with actual numbers**: this repo's studies (single 7B-class
  model, single replica, no production traffic volume) fail all three of this chapter's
  disaggregation preconditions cleanly — 100M+ tokens/day and 100B+ params are both far
  beyond current scope. This is a stronger, more falsifiable statement than the existing
  "N/A until multi-replica scope" framing — worth a `ROADMAP.md` update citing concrete
  numbers instead of a qualitative "not yet."
- **Directly reinforces H5** (tensor_parallel_size "minimum that fits") with a concrete
  sizing formula (`bits_precision/8 × params × kv_cache_allocation`) a future multi-GPU
  study could use to *compute* its own minimum TP degree from first principles, rather
  than guessing — complementary to H5's existing qualitative guidance.
- **The "disable speculative decoding at high batch sizes" mechanism should be added to
  the existing speculative-decoding pack-request note in `ROADMAP.md`'s debt section** —
  it currently records that speculative decoding's benefit "shrinks or inverts" at large
  batch sizes but doesn't yet capture that production engines *dynamically disable* it
  rather than merely seeing reduced benefit; worth confirming whether the installed
  vLLM pack's speculative-decoding config (once added) needs a batch-size-conditional
  toggle, not just a static method/draft-model selection.
- **Explains, with a specific mechanism, why `0-explorative`'s winning configuration
  paired `FLASHINFER` with `kv_cache_dtype=fp8_e4m3` and not with attention
  quantization** — this repo's own result already matches this chapter's component-
  sensitivity ranking (KV cache is the moderate-risk, most-commonly-quantized component;
  attention is the highest-risk, rarely-quantized one) without having reasoned about it
  explicitly at the time. Worth citing in that study's README as a why on this specific
  point, if not already covered by the existing incident narrative.

## Which Akamas parameters to explore

Reinforces (does not add new distinct parameters beyond) items already tracked in
`ROADMAP.md`'s pack-request debt: `kv_cache_dtype`/FP8-FP4 quantization (already the
most plausible near-term ask), speculative decoding config (`--speculative-config`,
now with the added nuance that any Akamas-modeled version should account for a
batch-size-dependent enable/disable, not just a static method choice), and
`tensor_parallel_size` (already modeled). Disaggregation topology (xPyD ratio) remains
what the existing llm-d/Dynamo notes already flagged as a deployment-architecture
choice outside a component's parameter list, not a per-instance parameter — this
chapter's concrete adoption thresholds are a refinement of *when* to consider that
gap relevant, not a change to what's asked of the pack owner.
