<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Practical Strategies for vLLM Performance Tuning

**Source:** [Red Hat Developer — Practical strategies for vLLM performance tuning](https://developers.redhat.com/articles/2026/03/03/practical-strategies-vllm-performance-tuning)
**Date distilled:** 2026-07-08

## Problem addressed

Counters the idea that vLLM tuning is "one magic flag" — argues it's an iterative process
balancing hardware constraints, workload shape, and latency/throughput targets, and gives
concrete starting-point guidance for the handful of parameters that matter most:
`gpu-memory-utilization`, `kv-cache-dtype`, `max-num-seqs`, and GPU-to-replica layout.
Much narrower in scope than the distributed-inference series (single-instance vLLM
tuning, not multi-node topology/disaggregation), but directly actionable for this repo's
current single-Component studies.

## Levers / parameters touched

- **`gpu-memory-utilization`**: fraction of VRAM allocated to model weights + KV cache;
  default 0.9. Article's tuning method: push it up incrementally until instability, then
  back off slightly for a safety margin — not a fixed target value.
- **`kv-cache-dtype`**: KV cache precision (default = model's native dtype; e.g.
  `fp8` option). Lower precision cuts per-token memory cost, raising max concurrent
  requests — at a quality cost that's model/use-case dependent.
- **`max-num-seqs`**: caps concurrently active requests (excess is queued rather than
  dropped). Article's tuning method: sweep concurrency to find the throughput
  saturation/plateau point, then set `max-num-seqs` near that point as the starting
  value, adjusting from there based on how much queuing latency vs. throughput
  stability is acceptable.
- **GPU-to-replica ratio / `tensor_parallel_size`** (framed as a layout choice, not a
  single flag): for a fixed GPU budget, more replicas at lower TP vs. fewer replicas at
  higher TP is a real trade space to test empirically, not assume.
- **Benchmarking methodology**: explicitly calls out that synthetic/simplistic
  benchmarks mislead — recommends GuideLLM with request shapes (prompt/response length
  distributions, concurrency pattern) matching actual production traffic, because
  repeated/reused prompts materially change results via vLLM's own caching behavior.

## Key results

- On NVIDIA H100, default `gpu-memory-utilization=0.9` can leave up to **~8 GB VRAM
  unused** by reserved-but-unallocated headroom when running smaller models; the
  article's suggested adjustment is 0.95 as a starting point to reclaim more of that for
  KV cache — stated as a rule of thumb tied to H100 + "smaller models," not a universal
  constant.
- Example replica-layout comparison given (no benchmark numbers, just a testing
  methodology): 16 GPUs across two 8×H100 nodes — compare 4 replicas × 2 GPUs, 2
  replicas × 4 GPUs, and 1 replica × 8 GPUs; notes that high-availability/scheduling
  flexibility needs can favor more, smaller replicas even if consolidated 8-GPU TP were
  marginally faster per-request.
- No quantitative before/after throughput or latency numbers are given for any of the
  three main parameters — the article is a tuning **methodology** piece (how to find the
  right value empirically) rather than a benchmark report with transferable numbers.
  Don't treat "0.95" or "8 GB" as targets to replicate; they're anecdotal starting points
  from one hardware/model combination.

## Implications for vLLM/k8s tuning

- This is the most directly applicable source so far for this repo's actual studies: all
  three headline parameters (`gpu_memory_utilization`, `max_num_seqs`,
  `tensor_parallel_size`) are already in the installed vLLM pack (confirm with
  `akamas describe optimization-pack vLLM`), and the article's
  "sweep concurrency to find the plateau, then set the parameter near it" methodology is
  essentially describing what an Akamas optimization study over these parameters should
  discover automatically — this is a manual-tuning description of the same search an
  Akamas study runs, useful as a sanity check on whether a study's found optimum matches
  informed-manual-tuning intuition, and as a source of a *reasonable default/starting
  domain* if a study needs one before data exists.
- The GuideLLM realistic-workload-shape point reinforces this repo's own
  `ROADMAP.md` Q2 (load generator choice) and the general principle in this repo's
  studies of using representative prompt/response distributions rather than synthetic
  fixed-length requests — no new information, but external validation of the existing
  practice.
- The `gpu-memory-utilization` "push until instability, back off" method is consistent
  with H2 (`knowledge` hypothesis that this parameter shows diminishing returns/risk past
  a threshold) — this article supplies the practical *search procedure* a human would use
  to find that threshold, which is roughly what Akamas's optimizer should also converge
  toward if H2 is correct.
- Condition to flag: the 0.95/8GB figures are H100 + "smaller models"-specific — a study
  on different hardware or a larger model should not assume 0.95 is a better default than
  0.9 without checking its own memory headroom.

## Which Akamas parameters to explore

- `vLLM.gpu_memory_utilization` (already modeled) — this article's empirical "push until
  instability" method is a manual analogue of what an Akamas study's optimizer should
  find; supports H2's framing and suggests a study could sanity-check its optimizer's
  found optimum against a quick manual binary-search as a cross-check.
- `vLLM.max_num_seqs` (already modeled) — same point: the "sweep concurrency, find the
  plateau" method described here is literally the mechanism H3 predicts; this article is
  a second independent source (alongside "Mind the Memory Gap") suggesting the
  plateau/saturation framing is standard vLLM operational knowledge, not just one paper's
  finding.
- `vLLM.tensor_parallel_size` (already modeled) — reinforces H5: this article treats
  replica-count vs. TP-degree as an empirical trade-off to test per deployment, matching
  H5's "minimum TP that fits, then scale via replicas" guidance from the distributed
  inference series.
- `vLLM.kv_cache_dtype` / KV cache quantization — **already flagged as likely missing**
  from the installed pack in
  `knowledge/notes/2026-07-distributed-inference-advanced-deployment-patterns.md` and
  logged in `ROADMAP.md`'s pack-request debt item; this article is a second independent
  source recommending it (FP8 KV cache) as a low-effort, single-flag lever, reinforcing
  that request rather than adding a new one — confirm via
  `akamas describe optimization-pack vLLM` whether it has since been added.
