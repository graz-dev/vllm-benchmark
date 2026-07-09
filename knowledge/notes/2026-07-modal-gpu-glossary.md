<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Modal GPU Glossary

**Source:** [Modal — GPU Glossary](https://modal.com/gpu-glossary) (Device Hardware, Device Software, Host Software, Performance sections)
**Date distilled:** 2026-07-08

## Problem addressed

A reference glossary (not a research finding or benchmark) defining GPU architecture and
performance-analysis vocabulary — SMs, tensor cores, warps, memory hierarchy, occupancy,
the roofline model, and (most usefully for this repo) precise definitions of GPU
utilization-style metrics as reported by profiling tools. Its main value here is
correcting a specific, actionable misconception about what "GPU utilization %" (as
reported by `nvidia-smi` or DCGM-based tooling — the same family of metrics the
installed GPU optimization pack exposes, confirm with
`akamas describe optimization-pack GPU`) actually measures.

## Levers / parameters touched

Not a tunable-parameter source — this is a metric-interpretation reference. Terms most
relevant to this repo's GPU metrics/analysis:

- **Streaming Multiprocessor (SM) utilization** vs. **`nvidia-smi`-style GPU
  utilization**: two different measurements, defined precisely below.
- **Occupancy**: ratio of active warps to an SM's maximum warp capacity.
- **Pipe utilization**: how fully a given execution pipe (e.g. tensor-core pipe) within
  an SM is used, distinct from whether the SM itself is "active."
- **Roofline model** / **arithmetic intensity** (operations per byte moved): the
  standard framework for classifying a kernel as compute-bound or memory-bound.
- **Memory bandwidth**, **memory coalescing**, **bank conflict**, **warp divergence**,
  **scoreboard stall**: lower-level causes of a kernel running below peak despite
  "looking busy" on a coarse utilization metric.

## Key results

- **The single most actionable, quotable fact**: `nvidia-smi`-style GPU utilization
  reports whether *any* kernel is running anywhere on the GPU — "if a kernel uses only
  one SM... it will achieve 100% GPU utilization while it is active, but the SM
  utilization will be at most one over the number of SMs — **under 1% in an H100
  GPU**." I.e. a GPU can report 100% utilized while using a negligible fraction of its
  actual compute resources. This is a definitional/architectural fact (H100's SM count),
  not an empirical benchmark result, but it's precise and quotable.
- **High SM utilization can still mean poor efficiency**: "high SM utilization with low
  pipe utilization indicates that your kernel is running on many SMs but not fully
  utilizing the computational resources within each one" — i.e. even SM utilization
  (a more granular metric than `nvidia-smi`'s) doesn't guarantee the tensor cores or
  other pipes inside those SMs are actually doing useful work.
- **Roofline model**: classifies a kernel as compute-bound (limited by arithmetic
  throughput) or memory-bound (limited by memory bandwidth) based on its arithmetic
  intensity (ops/byte) relative to a hardware-specific "ridge point" — the minimum
  arithmetic intensity needed to be compute-bound rather than memory-bound on that GPU.
  No universal numeric threshold is given (it's hardware-specific, derived from that
  GPU's peak FLOPs and peak memory bandwidth), but the framework itself is the reusable
  artifact.
- This is a glossary, not a study — no workload-specific numbers or conditions to record
  beyond the H100 SM-count example above.

## Implications for vLLM/k8s tuning

- **Directly explains why "Mind the Memory Gap"'s finding is possible**
  (`knowledge/notes/2026-07-gpu-memory-bound-large-batch-inference.md`): that paper found
  attention kernels stalling on memory >50%/>80% of cycles at the throughput "plateau"
  while a coarse utilization metric might still look high — this glossary's SM-vs-
  `nvidia-smi`-utilization distinction and the roofline model are exactly the concepts
  needed to interpret *why* a GPU can look "busy" while being memory-bandwidth-bound, not
  compute-bound. Treat this note as the conceptual toolkit for reading GPU metrics from
  any future study, not as new evidence itself.
- **Direct caution for interpreting this repo's own GPU pack metrics**: if a future
  study (e.g. backlog #3, energy efficiency, or any GPU-monitoring analysis) uses a
  DCGM-reported "GPU utilization" metric, don't treat a high value as proof the workload
  is compute-bound or that more concurrency won't help — per this glossary, that metric
  can be near-meaningless for judging actual compute saturation. Whether the installed
  GPU pack's metrics distinguish SM-level utilization from simple "any kernel running"
  utilization needs to be checked with `akamas describe optimization-pack GPU` before
  relying on either metric name to mean what it sounds like it means.
- Useful shared vocabulary for anyone on this repo interpreting Nsight Compute/Nsight
  Systems traces (already referenced as a diagnostic tool in
  `knowledge/notes/2026-07-distributed-inference-blueprints-troubleshooting.md`'s
  troubleshooting playbook) — this glossary is literally scoped (per its own overview)
  to "every term you run across when using NSight Compute to debug GPU kernel
  performance issues."

## Which Akamas parameters to explore

- No parameters — this is a metric-interpretation reference, not a tunable-knob source.
  One concrete follow-up worth doing rather than requesting: confirm via
  `akamas describe optimization-pack GPU` exactly which utilization-family metric(s) the
  installed GPU pack exposes (coarse `nvidia-smi`-equivalent vs. SM-level vs. per-pipe/
  tensor-core-level) so that any future study's analysis correctly interprets what
  "GPU utilization" means in that pack's specific metric, rather than assuming it means
  full compute saturation.
