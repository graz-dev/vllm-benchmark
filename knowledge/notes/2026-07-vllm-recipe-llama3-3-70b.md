<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# vLLM Official Recipe: Llama 3.3-70B

**Source:** [vllm-project/recipes — Llama/Llama3.3-70B.md](https://github.com/vllm-project/recipes/blob/main/Llama/Llama3.3-70B.md)
**Date distilled:** 2026-07-08

## Problem addressed

An official vLLM-project reference config for serving Llama-3.3-70B (FP8/FP4 quantized
NVIDIA checkpoints) on NVIDIA Blackwell (B200) or Hopper (H100/H200) GPUs — not a
research finding, but a maintained "known-good starting point" recipe with concrete flag
values and three named deployment profiles (max throughput / min latency / balanced).
Useful as a cross-check for whether this repo's own vLLM parameter domains are in a
sane range for a 70B-class dense model, distinct from the general tuning-methodology
sources already in this knowledge base.

## Levers / parameters touched

- `--kv-cache-dtype fp8` — recommended across both Blackwell and Hopper as giving "best
  performance."
- `--async-scheduling` — reduces host-side overhead between decode steps.
- `--no-enable-prefix-caching` — recommended *off* specifically for consistent synthetic
  benchmarking (i.e. a benchmarking-methodology flag, not a production recommendation to
  disable prefix caching generally).
- `--tensor-parallel-size` (TP) — values 1/2/4/8 tested; explicitly framed as a
  throughput-vs-latency dial: TP=1 maximizes per-GPU throughput, higher TP reduces
  latency (more GPUs sharing the compute per request) at some throughput cost.
- `--max-num-batched-tokens` — 8192 recommended baseline; 16384 "marginal gains."
- `--max-num-seqs` — tunable batch-size knob; recipe explicitly says to reduce it below
  vLLM's default 1024 if actual production concurrency is lower than that.
- `--max-model-len` — set per actual input+output token budget, not left at model max.
- Blackwell-only compiler pass config: `fuse_allreduce_rms`, `fuse_attn_quant`,
  `eliminate_noops` (not supported on Hopper) — a hardware-generation-specific flag, not
  transferable to H100/H200 setups.

## Key results

- **Three named profiles on B200**, each a TP/`max-num-seqs` pair, not independent
  sweeps:
  - Maximum throughput: TP=1, `max-num-seqs` pushed to the maximum the GPU/KV cache
    supports.
  - Minimum latency: TP=4 or 8, `max-num-seqs` small (e.g. 8).
  - Balanced: TP=2, `max-num-seqs`=128.
- Explicit statement of the TP/batch-size interaction mechanism: "increasing TP (which
  would lower the throughput at the same batch size) may allow a higher batch size to
  run (which would increase throughput)" — i.e. TP and `max-num-seqs` are not
  independent levers; a TP increase's KV-cache-per-GPU relief can let `max-num-seqs` go
  higher than it could at lower TP, partially offsetting TP's own per-request throughput
  cost.
- One accuracy benchmark given (not a performance/throughput number): single B200, FP4,
  GSM8K — flexible-extract 0.9272 (±0.0072), strict-match 0.6293 (±0.0133); benchmark
  workload was 1024-token average input/output, max concurrency 512, 2560 total prompts.
  This is a quality/accuracy check for the FP4 quantized checkpoint, not a latency or
  throughput result — don't treat it as a performance number.
- No multi-node setup guidance is given; the whole recipe assumes single-node
  multi-GPU (TP ≤ 8, i.e. within one node's GPU count).

## Implications for vLLM/k8s tuning

- This is model-and-hardware-specific (Llama-3.3-70B FP8/FP4 on B200/H100/H200) — the
  exact numbers (8192 batched tokens, TP=2/BS=128 "balanced," `max-num-seqs`=8 for min
  latency) should NOT be copied verbatim if a study uses a different model size, GPU
  generation, or quantization — but they're a good sanity-check reference range for a
  70B-class dense model specifically.
- The TP/`max-num-seqs` coupling is a concrete, named mechanism for something this
  knowledge base has only discussed at a higher level so far (H5's "TP degree vs. replica
  count" and the practical-tuning note's "GPU-to-replica ratio is an empirical
  trade-off"): here it's the *same-replica* interaction — raising TP frees KV-cache
  headroom per GPU that lets `max-num-seqs` rise too, so sweeping TP and `max-num-seqs`
  independently (holding one fixed while varying the other) may miss the actual joint
  optimum. Relevant to how a study's `parametersSelection` should be scoped if it
  searches both `tensor_parallel_size` and `max_num_seqs` together — Akamas already
  searches them jointly by nature of multi-parameter optimization, but this confirms the
  interaction is real and worth checking in results rather than assuming independence.
- `--no-enable-prefix-caching` being recommended specifically *for benchmarking* (to get
  consistent, repeatable numbers unaffected by cache warm state) is a useful
  benchmarking-hygiene note distinct from a production recommendation — this repo's
  studies should decide explicitly whether prefix caching is on or off during a benchmark
  run and record which, since it changes what's actually being measured.

## Which Akamas parameters to explore

- `vLLM.tensor_parallel_size` and `vLLM.max_num_seqs` (both already modeled) — this
  recipe is a concrete illustration of why these two should be treated as a coupled pair
  rather than tuned independently; if a study's Akamas `parametersSelection` includes
  both, no additional pack support is needed, but the study's own analysis of results
  should look for the coupling described here rather than analyzing each parameter's
  effect in isolation.
- `vLLM.max_num_batched_tokens` (already modeled) — recipe's 8192 baseline / 16384
  marginal-gains data point is a useful reference for scoping a study's domain for a
  70B-class dense model, distinct from H1's more general TTFT/throughput trade-off
  hypothesis.
- `vLLM.kv_cache_dtype` — **already flagged as missing** from the installed pack (see
  `ROADMAP.md`'s pack-request debt item, sourced from two earlier notes); this is now a
  third independent source recommending FP8 KV cache as a near-default-quality lever,
  further reinforcing that request rather than adding a new one.
- `--async-scheduling` and prefix-caching on/off were not in this repo's tracked vLLM
  parameter summary either — likely lower priority to request than `kv_cache_dtype` (this recipe
  frames prefix-caching toggling as a benchmarking-methodology concern, not a production
  tuning target), but worth checking with `akamas describe optimization-pack vLLM` if a
  future study wants to control benchmarking hygiene through Akamas itself rather than
  fixing it in the study's load-test manifest.
