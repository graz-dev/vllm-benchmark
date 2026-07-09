<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Continuous vs. Dynamic Batching for AI Inference

**Source:** [Baseten Blog — Continuous vs. dynamic batching for AI inference](https://www.baseten.co/blog/continuous-vs-dynamic-batching-for-ai-inference/)
**Date distilled:** 2026-07-08

## Problem addressed

Explains the mechanical difference between batching strategies for model serving —
no batching, static batching, dynamic (request-level, timeout-based) batching, and
continuous (token-level, iteration-level) batching — and why LLM serving specifically
benefits from the last one. This is a mechanism explainer, not a benchmark report: it
has no throughput/latency numbers, but it's the clearest available explanation in this
knowledge base of *why* vLLM's core scheduling behavior (and therefore
`max_num_seqs`/`max_num_batched_tokens`) works the way every other note here assumes it
does — worth keeping despite the lack of numbers because it's foundational, unlike the
"LLM Performance on GPU" overview note (which was dropped as redundant filler); this one
fills a genuine conceptual gap none of the more benchmark-heavy notes explain from
first principles.

## Levers / parameters touched

- **Dynamic batching**: two parameters — a target maximum batch size, and a time window
  to wait after the first request arrives before running a partial batch if the target
  size isn't reached (example given: batch size 16, window 100ms — whichever condition
  hits first triggers execution). This is a **request-level** batching unit: the whole
  batch starts and finishes together.
- **Continuous batching**: batches at the **token level**, not the request level — the
  model server applies each model layer to "the next token of each request" per
  iteration, so a single forward pass can simultaneously compute, e.g., token 5 of one
  request and token 85 of another. New requests join and finished requests leave the
  running batch between iterations, not only at a batch boundary. Governed by a max
  concurrent-request limit (this is what `max_num_seqs` is, mechanically) and expected
  sequence-length shape (relevant to `max_num_batched_tokens`).
- Named engines: vLLM and TGI use continuous batching; TensorRT-LLM calls its equivalent
  "in-flight batching" — same underlying mechanism, different vendor name.

## Key results

**No benchmark numbers are given** — the article references its own separate
Mistral-7B benchmarking post and a "batch size vs. latency" guide without including
their numbers inline. The only "result" here is the qualitative mechanism claim:
continuous batching eliminates the idle GPU time that dynamic/static batching incurs
while "waiting for the longest response of each batch to finish" — i.e. dynamic
batching's throughput is bounded by its slowest request per batch, while continuous
batching lets shorter-output requests leave and new ones enter without waiting on the
batch's longest member. No conditions (hardware/model/workload) are attached to any
number because no number is given; treat this note as purely mechanistic, not
evidentiary.

## Implications for vLLM/k8s tuning

- This is the clearest available explanation of *why* `max_num_seqs` behaves the way
  H3 hypothesizes (throughput growing with concurrency, then saturating): under
  continuous batching, `max_num_seqs` is literally the cap on how many token-level
  "slots" run per iteration — raising it lets more requests share each iteration's GPU
  pass until the KV cache or compute saturates, at which point the mechanism this
  article describes (per-iteration token-level packing) can't extract more parallelism
  and throughput plateaus. This is the mechanism explanation "Mind the Memory Gap"
  measures empirically and this article names conceptually.
- Reinforces why this repo's studies shouldn't need to think about static/dynamic
  request-level batch-size or a timeout-window parameter at all for vLLM — those are
  the *dynamic*-batching family's parameters (relevant to non-LLM model servers like
  Stable Diffusion, per the article's own example), not vLLM's continuous-batching
  model, which is governed by `max_num_seqs`/`max_num_batched_tokens` instead. Useful to
  rule out "should we also tune a batch timeout" as a question for a vLLM study — no,
  that parameter doesn't apply to vLLM's batching model.
- No condition-specific findings to flag since no benchmark numbers are given — the
  mechanism itself is general to any continuous-batching engine (vLLM, TGI,
  TensorRT-LLM's in-flight batching), not tied to a particular hardware or model size.

## Which Akamas parameters to explore

- No new parameters or pack-request items — `max_num_seqs` and `max_num_batched_tokens`
  (both already modeled, confirmed via `akamas describe optimization-pack vLLM`) are exactly the two
  continuous-batching control points this article describes; this note doesn't surface
  anything not already covered, it explains the mechanism *behind* those two parameters
  more clearly than any prior note in this knowledge base.
