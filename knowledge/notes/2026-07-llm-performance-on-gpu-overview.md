<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# LLM Performance on GPU: Factors, Bottlenecks, and Best Practices

**Source:** [Medium (curateai) — LLM performance on GPU: factors, bottlenecks, and best practices](https://curateai.medium.com/llm-performance-on-gpu-factors-bottlenecks-and-best-practices-0a373e158c24)
**Date distilled:** 2026-07-08

## Problem addressed

A general-audience introductory overview of what determines LLM inference speed on a
GPU (model size, VRAM capacity, memory bandwidth, sequence length, output length) and
the standard optimization toolbox (quantization, KV caching, PagedAttention,
FlashAttention, kernel fusion). Unlike every other source in this knowledge base, this
article gives **no concrete benchmark numbers, no specific hardware/model conditions,
and no novel findings** — it's a restatement of well-established concepts already
covered in more depth and with actual measurements by other notes here
(`knowledge/notes/2026-07-gpu-memory-bound-large-batch-inference.md`,
`knowledge/notes/2026-07-practical-vllm-performance-tuning.md`, and the
distributed-inference series). Recorded for completeness since it was explicitly
requested, but should not be treated as an independent evidentiary source — it's a
plain-language summary of concepts, not a primary source with new data.

## Levers / parameters touched

- VRAM capacity — called "the #1 factor"; insufficient VRAM forces CPU offloading,
  described as "a major bottleneck," with the generic recommendation that a model
  should fit entirely on-device.
- Memory bandwidth — how fast the GPU can read/write VRAM per layer, distinct from
  capacity.
- Sequence length (prompt) — TTFT scales up because self-attention cost scales with the
  square of sequence length (a qualitative restatement of the well-known O(n²) attention
  cost already covered quantitatively by the distributed-inference series' PCP
  discussion).
- Output length (`max_new_tokens`) — each additional output token costs one more full
  forward pass; generic advice to cap this to the application's actual need rather than
  a high default.
- Quantization (4-bit/8-bit via bitsandbytes) — reduces VRAM and can speed up inference;
  the article's only quantitative-ish guidance is a qualitative floor ("don't go below
  4-bit") without justifying numbers.
- KV caching, PagedAttention, FlashAttention, kernel fusion — named and described at a
  conceptual level (what they do), not how to configure or tune them.

## Key results

**None given.** This is the article's most important limitation as a knowledge-base
source: no throughput/latency numbers, no hardware, no model sizes with measured
results, no thresholds beyond a qualitative "don't quantize below 4-bit" and "start
model exploration at 7B–13B before 70B." Every concept it names is covered with actual
measured conditions elsewhere in this knowledge base (e.g. the quadratic-attention/TTFT
relationship is quantified with real numbers in the distributed-inference scaling-
dimensions note; PagedAttention's memory-plateau behavior is measured in "Mind the
Memory Gap"). Treat this source as a plain-language index of terms, not evidence.

## Implications for vLLM/k8s tuning

- No new implications beyond what's already established by better-sourced notes in this
  knowledge base. Its only practical value is as a glossary/onboarding reference for
  someone unfamiliar with why `gpu_memory_utilization`, `max_num_batched_tokens`, and
  `max_num_seqs` matter in the first place — not as a source to cite for a study's
  actual parameter choices or expected results.
- The "cap `max_new_tokens`/output length to what's actually needed" advice is a
  workload-design point (set via the load generator / application, not a vLLM server
  parameter) rather than something a study's `parametersSelection` would touch — vLLM
  server parameters don't set a hard output-length cap per se; that's typically a
  request-level `max_tokens` field the client sends, out of scope for this repo's
  server-side tuning studies.

## Which Akamas parameters to explore

None — this source names no parameter, threshold, or metric not already covered (with
actual measured conditions) by other notes in this knowledge base. No new pack-request
items follow from it.
