<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# AI Systems Performance Engineering — Serving-Level Tuning, Batching, Quantization, and Troubleshooting

**Source:** Chris Fregly, *AI Systems Performance Engineering* (O'Reilly, Nov 2025) —
Chapter 16 "Profiling, Debugging, and Tuning Inference at Scale", and the serving-relevant
sections of the Appendix "AI Systems Performance Checklist (175+ Items)" (pp. 947–988).
Local copy: `knowledge/sources/AI Systems Performance Engineering.pdf`.
**Date distilled:** 2026-07-08

## Problem addressed

Chapter 16 is a production-tuning/troubleshooting guide for a *running* inference
service: batching strategy, quantization, application-level tricks (prompt compression,
prefix caching, model cascading, streaming), and a symptom→cause→fix diagnostic
reference. The Appendix is a 175+-item checklist spanning the *entire* AI systems stack
— most of it (CUDA kernel tuning, NUMA/OS tuning, distributed-training network
optimization, data-loading pipelines) is **out of this repo's scope**: it's either
training-specific or below the level this repo tunes (raw CUDA/driver/OS internals are
explicitly managed outside this repo per `CLAUDE.md`). This note distills only the
appendix sections relevant to vLLM/Kubernetes serving-level tuning: "Efficient Inference
and Serving," "Multinode Inference and Serving," "GPU Resource Management and
Scheduling" (MIG/MPS — relevant to the GPU-sharing-scheduler question already in
`ROADMAP.md`), and "Power and Thermal Management" (relevant to backlog #3, the energy
study). Everything else in the appendix is noted as skipped, not silently omitted.

## Levers / parameters touched

- **Batching**: static vs. dynamic (request-level, timeout-bounded) vs. continuous
  (token-level, iteration-level — what vLLM does); chunked prefill / stall-free
  scheduling (splits long prefills into fixed-size chunks interleaved with decode).
- **Quantization**: weight-only (GPTQ, AWQ) at 4-bit; activation quantization (INT8,
  SmoothQuant); combined weight+activation (W4A8); FP8/FP4 (NVIDIA Transformer
  Engine, per-tensor/per-channel/per-block "microscaling").
- **Application-level, no model/hardware change required**: prompt compression/
  cleansing, dialogue summarization/truncation, prefix caching (`enable_prefix_caching`
  in vLLM), model cascading (route to a smaller model first), streaming response
  batching (tokens-per-flush), debouncing/request coalescing, output token limits and
  generation timeouts.
- **GPU sharing** (appendix): NVIDIA MPS (concurrent kernel execution from different
  processes on one GPU) and MIG (hard-partitioned GPU instances, up to 7 slices) as two
  distinct GPU-sharing mechanisms with different trade-offs (MPS = better for
  underutilized jobs that can share cycles; MIG = hard isolation/guaranteed resources for
  smaller-than-a-full-GPU jobs, not for tightly-coupled parallel jobs).
- **Power management** (appendix): GPU power limit (`nvidia-smi -pl`), clock locking
  (`nvidia-smi -lgc`), throttle-reason monitoring (`DCGM_FI_DEV_CLOCK_THROTTLE_REASONS`).

## Key results

- **Table 16-1 troubleshooting reference** (symptom → probable cause → action) — the
  book itself calls these values "illustrative," not architecture-specific benchmarks,
  but the diagnostic *mappings* are reusable: SM utilization <50% → small
  batches/unfused kernels → increase batch size, enable FlashAttention/fused SDPA; **KV
  cache preemption warnings → insufficient KV cache space → raise
  `gpu_memory_utilization`, lower `max_num_batched_tokens`**; high p95 tail latency →
  decode-node hotspot/head-of-line blocking → inspect routing, enable speculative
  decoding; **cache-hit rate <60% under load → unbalanced shard placement or missing
  prefix cache → validate prefix-caching config, increase TTL/replica count**;
  unexpected OOM on multitenant GPU → overcommitted memory → lower per-instance
  `gpu_memory_utilization`, enable CPU/NVMe offload; irregular outliers → clock
  mismatch/thermal throttling → verify clock sync, monitor thermal/power throttling.
- **Table 16-3 example Prometheus alert thresholds**: GPU utilization <10% for ≥60s
  (idle); >90% (possible saturation); memory >80% (warning)/>95% (critical);
  temperature >85°C (warning)/>95°C (critical); any NVLink replay/CRC error or
  uncorrectable ECC error → critical. Stated as illustrative defaults to adapt, not
  universal thresholds.
- **Quantization**: 4-bit weight-only (GPTQ) "can retain 99%+ of the accuracy of the
  FP16 model" for many large models, with **~2× inference speedup and ~4× smaller
  footprint**. AWQ improves accuracy further at 3–4 bit by preserving "salient" weight
  channels. SmoothQuant enables full INT8 (weights+activations) with **<1% accuracy
  loss**, calibration-free. Summary guidance given explicitly: **"start with 8-bit
  weights, then evaluate 4-bit weight-only... then move to W4A8 only if you need maximum
  optimization and can spend time on calibration."**
- **Batch-size headroom rule of thumb**: teams commonly **target ~90% of peak
  throughput** as an operating point rather than the literal peak, because running at
  100% utilization/max batch size can cause unpredictable latency spikes and thermal/
  power throttling — "sometimes running at 90% with efficient kernels can outperform
  100% with throttling." This is a heuristic for picking a *final* operating
  configuration, not a domain-bound recommendation for a search.
- **Streaming pacing target**: human reading speed is ~4–7 tokens/sec (up to ~13 for
  fast readers) — a useful floor when judging whether observed decode throughput is
  "fast enough" from a UX perspective, distinct from raw throughput optimization.
- **Chunked prefill does not reduce total attention compute** — worked example: a
  20K-token prompt's self-attention cost sums to the same ~200M ops regardless of
  whether it's chunked into 1, 2, or 4 pieces (attention cost is O(N²), triangular);
  chunking only changes *when* decode work becomes available, i.e. it smooths latency,
  it doesn't reduce total FLOPs.
- **Power-capping headroom (Appendix, "Power and Thermal Management")**: "for some
  models, going from a 100% to 80% power limit yields nearly the same speed at 20% less
  power usage" — a concrete, testable claim directly relevant to backlog #3 (the
  planned tokens/s-per-watt energy study): power capping may be a near-free efficiency
  win for memory-bound workloads specifically, worth testing as a first experiment
  before assuming max power limit is optimal.
- **MIG vs. MPS guidance (Appendix)**: MIG gives hard resource guarantees, up to 7
  partitions per modern GPU, but is unsuitable for tightly-coupled parallel jobs (e.g.
  TP-sharded inference) — use only when jobs are individually smaller than a full GPU.
  MPS allows concurrent kernel execution without full isolation, suited to jobs that
  individually underutilize the GPU. Both are distinct from Run:ai's fractional-GPU
  scheduler already logged in `ROADMAP.md`'s H4 evidence — this is a third/fourth
  possible answer to the "does the target cluster have a GPU-sharing scheduler"
  question already flagged as a debt item.

## Implications for vLLM/k8s tuning

- **The Table 16-1 troubleshooting mappings directly extend the existing operating
  practice already in `ROADMAP.md`** ("diagnosing anomalous study runs," sourced from
  the blueprints-troubleshooting note): specifically, "KV cache preemption warnings" and
  "cache-hit rate <60%" are two additional named symptom→cause→fix mappings not yet
  captured there, and they name the *exact* parameters this repo already models
  (`gpu_memory_utilization`, `max_num_batched_tokens`) as the fix — directly actionable
  for interpreting any future study's anomalous results.
- **Quantization guidance reinforces the existing `kv_cache_dtype` pack-request** (already
  logged, sourced from the practical-vllm-tuning and Llama-3.3-70B-recipe notes) with a
  stronger, more general claim: GPTQ/AWQ weight quantization is described as reliably
  near-lossless (99%+ accuracy) with ~2× speedup for *many* large models, not just a
  model-specific anecdote — supports treating quantization as a "calibrate once, don't
  search" parameter (same pattern as H2's `gpu_memory_utilization`-ceiling suggestion)
  rather than something to sweep inside an Akamas study, once/if the pack exposes it.
- **The 90%-of-peak-throughput heuristic** is relevant to how a study's *recommended*
  final configuration gets chosen from Pareto-optimal results, not to how
  `parametersSelection` domains are set — worth keeping in mind when a study reports
  "best" configs: the literal throughput-maximizing point may not be the one to
  recommend for production if it sits at a latency-spike-prone edge.
- **Power-capping evidence is new, concrete, and directly actionable for backlog #3**
  (not yet started) — see ROADMAP proposal below.
- **MIG/MPS detail adds nuance to the existing GPU-sharing-scheduler debt item**: when
  that item gets investigated, the answer isn't binary ("has a scheduler or not") — MIG,
  MPS, and Run:ai-style fractional scheduling have different trade-offs and should be
  confirmed distinctly, not treated as interchangeable.
- Chunked prefill's "doesn't reduce total compute, only latency shape" finding is a
  useful caution: if a future study or pack update exposes a chunked-prefill-size
  parameter, its effect should be evaluated on latency distribution (TTFT smoothing),
  not on throughput/total-compute reduction — don't expect a throughput win from it.

## Which Akamas parameters to explore

- No new parameters beyond what's already logged in `ROADMAP.md`'s pack-request debt
  item — this source reinforces `gpu_memory_utilization`, `max_num_batched_tokens`
  (both already modeled) and `kv_cache_dtype` (already flagged as missing) rather than
  surfacing new ones.
- Confirms (does not newly discover) that a **cache-hit-rate metric** distinct from
  cache-*usage*/occupancy would be needed to act on the "cache-hit rate <60%"
  troubleshooting symptom — same open question as `ROADMAP.md`'s Q4, no new action
  needed beyond what Q4 already asks (confirm via `akamas describe optimization-pack
  vLLM`).
- Power-capping (`nvidia-smi -pl`) is a **GPU-level, not vLLM-level**, lever — confirm
  whether the installed GPU pack exposes a power-limit parameter (this repo's own
  tracking at the time listed the GPU component type as metrics-only, no tunable
  parameters — re-check with `akamas describe optimization-pack GPU`) before assuming
  backlog #3 can
  actually tune this via Akamas; if not exposed, backlog #3 may need to fix power limit
  outside Akamas (e.g. via a workflow task) rather than as a `parametersSelection` entry.

## Proposed `ROADMAP.md` additions (not yet applied — confirm before editing)

1. **New operating-practice bullet**, extending the existing troubleshooting practice in
   section A: add "KV cache preemption warnings → raise `gpu_memory_utilization` or
   lower `max_num_batched_tokens`" and "cache-hit rate <60% → check prefix-caching
   config, not the parameter under test" as two more named symptom→fix mappings, sourced
   from this note's Table 16-1.
2. **New note under backlog #3** (energy efficiency study, currently `IDEA`/not started):
   flag the power-capping finding ("100%→80% power limit ≈ same speed at 20% less power
   for some models") as a candidate first experiment/prior, and flag that the GPU pack
   may not expose a tunable power-limit parameter (metrics-only per the pack summary) —
   worth confirming with `akamas describe optimization-pack GPU` before scoping that
   study's `parametersSelection`.
3. **Extend the GPU-sharing-scheduler debt item** to explicitly name MIG and MPS as
   distinct mechanisms to check for (in addition to Run:ai), each with different
   trade-offs (MIG = hard partition/isolation, unsuitable for TP-sharded jobs; MPS =
   soft concurrent sharing) rather than treating "has a GPU-sharing scheduler" as a
   single yes/no fact about the target cluster.
