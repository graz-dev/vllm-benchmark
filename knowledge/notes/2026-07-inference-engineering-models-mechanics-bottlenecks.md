<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Inference Engineering — LLM Inference Mechanics and the Roofline/Bottleneck Model

**Source:** *Inference Engineering* by Philip Kiely (Baseten Books, 2026), Chapter 2
"Models" (`knowledge/sources/Inference Engineering.pdf`, printed pages 39-70).
**Date distilled:** 2026-07-13

## Scope note

This chapter also covers image/video generation model mechanics (diffusion
transformers, latent space, SDXL/Qwen Image pipelines, few-step distillation) — not
distilled here, since this repo's studies serve text-only LLMs (Qwen2.5-7B-Instruct via
vLLM), not image/video generation. Only the LLM-mechanics and the (modality-agnostic)
roofline/bottleneck framework are pulled out below.

## Problem addressed

Explains, from first principles, *why* vLLM's two inference phases (prefill/decode)
have opposite hardware bottlenecks — the mechanistic reason behind several hypotheses
already in `ROADMAP.md` (H1's TTFT/throughput split, H3's `max_num_seqs` saturation
behavior) rather than new parameter findings themselves.

## Levers / parameters touched

Not a specific vLLM flag — the conceptual/diagnostic framework underneath several
already-tracked parameters: arithmetic intensity / roofline analysis (why prefill is
compute-bound and decode is memory-bound), attention-optimization implementation choice
(`vLLM.attention_backend`, already modeled per the pack's `FLASH_ATTN`/`FLASHINFER`/
`TRITON_ATTN` categories), and KV-cache paging (PagedAttention, the mechanism underlying
`vLLM.block_size`, also already modeled).

## Key results

- **The roofline model, in concrete numbers**: an H100 in FP16 has an ops:byte ratio of
  ~295 (989 TFLOPS ÷ 3.35 TB/s) — a kernel is compute-bound if its arithmetic intensity
  (total FLOPs ÷ total bytes moved) exceeds this, memory-bound if below. Worked example
  for decode attention (128-dim head, 4096-token sequence, FP16): arithmetic intensity
  computes to **62 ops:byte — well below H100's 295 ceiling, confirming decode is
  memory-bound** by direct calculation, not just assertion. This is the same conclusion
  already assumed in this repo's H1/H3 discussions, now with the actual derivation.
- **Prefill is compute-bound, decode is memory-bound, image/video generation is
  compute-bound** (stated as the chapter's central bottleneck classification) — the
  mechanistic reason: prefill processes the whole input sequence in one pass (many FLOPs
  per byte of memory read, since weights are loaded once and reused across all input
  tokens), while decode reloads the model's weights from memory for every single new
  token generated (one token's worth of compute per full weight-read).
- **Batching moves decode's bottleneck**: batching multiple requests together increases
  compute per byte of memory traffic (the weights are read once but multiplied against
  more requests' data), making decode less memory-bound — the direct mechanistic
  explanation for why `max_num_seqs`/`max_num_batched_tokens` raise throughput (H1, H3):
  they're not just "more concurrency," they're shifting decode's own bottleneck ratio
  toward the compute-bound side of the roofline.
- **MoE (Mixture of Experts) architecture**: sparsifies linear layers into many small
  "expert" matrices, activating only a subset per token (e.g. Qwen3-235B-A22B activates
  22B of 235B total parameters per request). Efficient for **single-request** inference,
  but under **batched serving** (this repo's actual workload shape), different
  concurrent requests activate different experts, so "you should expect almost all
  parameters to be active at any given time" unless Expert Parallelism specifically
  targets sparsity — **not applicable to this repo's dense Qwen2.5-7B-Instruct model**,
  but relevant framing if a future study serves a larger MoE model (e.g. Qwen3-MoE,
  DeepSeek).
- **Attention optimization taxonomy**: two strategies — (1) **implementation
  improvements** (lossless, don't change output quality): FlashAttention (fused kernels
  eliminating intermediate-matrix memory round-trips, GPU-generation-specific code) and
  **PagedAttention** (partitions KV cache into non-contiguous pages via a lookup table —
  this is the mechanism `vLLM.block_size` directly controls, already modeled by the
  installed pack); (2) **new algorithms** (trade quality for sub-quadratic scaling):
  sliding-window attention (`O(Nw)` instead of `O(N²)`, w typically 8K-32K), gated/
  linear/compressed/multi-latent attention, and non-transformer alternatives like Mamba
  (state-space models, linear scaling, adopted by NVIDIA Nemotron 3 Nano as a hybrid).
  None of the "new algorithm" variants apply to this repo's current model (a standard
  dense transformer), but useful context if a future study evaluates a long-context or
  hybrid-architecture model.

## Implications for vLLM/k8s tuning

- **Directly explains, mechanistically, why H1 and H3 behave the way this repo's own
  data already showed**: `studies/0-explorative`'s finding that `max_num_seqs` kept
  improving throughput without a clear plateau (H3, leans rejected) and that
  `max_num_batched_tokens` showed near-zero correlation with a throughput-only goal (H1,
  not cleanly testable) both make sense under this chapter's framing — decode is
  memory-bound by default, and these parameters work by pushing more compute per byte of
  memory traffic (batching), not by changing the KV-cache-deficit mechanism H2 already
  covers. No new hypothesis needed — this strengthens the existing ones with a causal
  mechanism rather than adding a new empirical claim.
- **The attention-optimization taxonomy confirms this repo's `attention_backend`
  parameter (added to the vLLM pack in `feature/attention-backend-and-block-size-
  categorical`) is choosing between "implementation improvements," not "new algorithms"**
  — `FLASH_ATTN`/`FLASHINFER`/`TRITON_ATTN` are all lossless, standard-quadratic-
  complexity implementations. None of the sub-quadratic "new algorithm" variants
  (sliding-window, linear, Mamba-hybrid) are exposed as options in the installed pack,
  because Qwen2.5-7B-Instruct is a standard dense transformer that doesn't use them —
  no gap to flag unless a future study picks a model architecture that specifically
  ships one of these (e.g. a sliding-window model like Mistral, or a Mamba-hybrid model).
- **MoE/Expert Parallelism is N/A for every study run so far** (dense model) — flagged
  only as a fact to remember if a future study serves an MoE model: batched-serving
  throughput assumptions from a dense model won't transfer, since MoE's efficiency
  advantage is request-count-dependent, not just parameter-count-dependent.

## Which Akamas parameters to explore

N/A for new parameters — this chapter is the conceptual foundation under
`vLLM.attention_backend` and `vLLM.block_size` (both already modeled) and under the
existing H1/H3 hypotheses, not a source of new tunable knobs. No `ROADMAP.md` action
needed beyond what H1/H3 already track — this note exists to give future readers of
those hypotheses the "why," not to add a new claim.
