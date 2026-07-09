<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# auto-tune-vllm (openshift-psap)

**Source:** [openshift-psap/auto-tuning-vllm (GitHub)](https://github.com/openshift-psap/auto-tuning-vllm) — README, `examples/study_config_optimization_examples.yaml`, `examples/trial_config_comprehensive.yaml`
**Date distilled:** 2026-07-08

## Problem addressed

An OpenShift-affiliated, alpha-stage (`v0.0.1-alpha`, released 2025-10-02) open-source
project doing essentially the same thing this repo uses Akamas for: automated
hyperparameter optimization of vLLM configurations, via Optuna (TPE for single-objective,
NSGA2 for multi-objective) distributed over Ray, benchmarked with GuideLLM (matching
`ROADMAP.md` Q2's load-generator choice) or custom benchmark providers, with trials/
metrics/logs stored in PostgreSQL. This is the closest thing yet in this knowledge base
to a **direct competitor/analogue of the Akamas-based approach this repo takes** — most
valuable here as a cross-check for parameter coverage and reasonable domain ranges,
since its maintainers independently arrived at a specific list of "worth tuning" vLLM
parameters and default-centered ranges.

## Levers / parameters touched

Full list of vLLM parameters shown in its example trial config
(`trial_config_comprehensive.yaml`), each with the project's own suggested search range/
options and rationale comment:

| Parameter | Range/options | Project's note |
|---|---|---|
| `gpu_memory_utilization` | 0.85–0.95, step 0.01 | "vLLM default: 0.9, optimize around it" |
| `kv_cache_dtype` | `auto`, `fp8` (also lists `fp8_e5m2`, `fp8_e4m3` as vLLM CLI options) | — |
| `swap_space` | 2–8 GB, step 2 | "vLLM default: 4 GB, test different values" |
| `max_seq_len_to_capture` | 4096 / 8192 / 16384 | "vLLM default: 8192, test common values" |
| `dtype` | `auto`, `bfloat16`, `float16` | model dtype |
| `enforce_eager` | boolean | "vLLM default: False, test both modes" |
| `max_num_batched_tokens` | 2048–16384, step 2048 | throughput optimization |
| `scheduling_policy` | `fcfs`, `priority` | — |
| `scheduler_delay_factor` | 0.0–0.1, step 0.01 | "vLLM default: 0.0, test small delays" |
| `tensor_parallel_size` | 1 / 2 / 4 | "vLLM default: 1, test parallelism options" |
| `data_parallel_size` | 1 / 2 | "vLLM default: 1, test data parallelism" |

A second config (`study_config_optimization_examples.yaml`) shows narrower example
ranges for two of these: `gpu_memory_utilization` 0.85–0.95 step 0.05, and
`max_num_batched_tokens` 1024–8192 step 1024 — i.e. even the project's own examples
don't agree on one canonical range, they're illustrative starting points, not a fixed
spec.

**Objective metrics** it optimizes against: `output_tokens_per_second` (throughput,
maximize), `request_latency` (end-to-end, minimize), `time_to_first_token_ms` (minimize),
`inter_token_latency_ms` (minimize) — each evaluable at `median`, `p90`, `p95`, or `p99`
percentile, enabling SLA-style objectives (e.g. optimize p95 TTFT, not just the mean).

**Search strategy**: single-objective via Optuna's TPE sampler; multi-objective
(throughput vs. latency trade-off) via NSGA2 — a genetic/evolutionary multi-objective
algorithm, notably different from Akamas's own optimization algorithm family, useful as
a point of comparison if Akamas ever exposes algorithm choice for a study.

## Key results

- No benchmark results or before/after numbers are published in the README or example
  configs — this is a tuning **framework**, not a study with findings; there's nothing
  quantitative to extract as "key results" beyond the parameter ranges and metrics
  above, which are themselves the useful artifact (a second, independent team's list of
  what's worth tuning and roughly what range to search).
- Maturity caveat: explicitly alpha (v0.0.1-alpha), with a documented known issue that
  Ray-cluster concurrency validation lacks resource-feasibility checks — treat this as
  an early-stage reference for parameter selection, not a production-ready tool to adopt
  directly.

## Implications for vLLM/k8s tuning

- **Direct value: parameter coverage cross-check.** Of the 11 parameters this project
  tunes, only three (`gpu_memory_utilization`, `max_num_batched_tokens`,
  `tensor_parallel_size`) match what's confirmed in the installed vLLM pack (confirm with
  `akamas describe optimization-pack vLLM` or the pack's own repo,
  https://gitlab.com/akamas/optimization-packs/vllm). The other eight
  (`kv_cache_dtype`, `swap_space`, `max_seq_len_to_capture`, `dtype`, `enforce_eager`,
  `scheduling_policy`, `scheduler_delay_factor`, `data_parallel_size`) are vLLM CLI flags
  an independent team considered worth optimizing but aren't confirmed present in this
  repo's pack — `kv_cache_dtype` was already flagged as missing by three earlier notes;
  the other seven are new candidates to check.
- **Range validation**: `gpu_memory_utilization` centered on 0.85–0.95 around the 0.9
  default matches "Practical Strategies for vLLM Performance Tuning"'s manual guidance
  (push toward 0.95) — two independent sources now suggest a narrow band above the
  default is the practically useful search space, not the full [0,1] domain.
  `max_num_batched_tokens` ranges (1024–8192 or 2048–16384 depending on which example
  config) both start well below the "Llama-3.3-70B recipe" note's 8192 baseline — a
  reminder that reasonable ranges are model/hardware-dependent, not universal.
- **`data_parallel_size` as a directly-tunable parameter** (not just "add more
  replicas") is notable: it suggests vLLM itself may expose data-parallelism as a launch
  flag distinct from a Kubernetes-level replica count — worth checking whether this maps
  onto the still-missing "Kubernetes replica-count" gap (H4/backlog #4) or is actually a
  *vLLM-internal* parameter that could close that gap without needing Kubernetes-pack
  support at all. Worth confirming with `akamas describe optimization-pack vLLM`.
- **`scheduling_policy` (fcfs/priority) and `scheduler_delay_factor`** are scheduler-
  level levers this knowledge base hasn't seen named explicitly before (the
  distributed-inference series discussed chunked prefill and preemption but not an
  explicit FCFS-vs-priority policy choice or a delay factor) — a new, specific
  parameter pair to check for in the installed pack.

## Which Akamas parameters to explore

- `vLLM.gpu_memory_utilization`, `vLLM.max_num_batched_tokens`,
  `vLLM.tensor_parallel_size` (already modeled) — this project's ranges are a useful
  reference/sanity-check for scoping a study's `parametersSelection` domain, alongside
  the other sources already reinforcing these three.
- **New pack-request candidates** (add to the existing ask in `ROADMAP.md`'s debt
  section rather than filing separately): `swap_space` (CPU-offload swap space for KV
  cache, GB), `max_seq_len_to_capture` (CUDA-graph capture length), `dtype` (model
  compute dtype), `enforce_eager` (disable CUDA graphs, boolean), `scheduling_policy`
  (`fcfs`/`priority`), `scheduler_delay_factor`, and `data_parallel_size`. Confirm each
  against `akamas describe optimization-pack vLLM` before assuming absence — this note's
  source is a third-party project's parameter choices, not a canonical vLLM parameter
  list, so some of these may already be present under a different name in the installed
  pack.
- `vLLM.kv_cache_dtype` — third independent source (after the advanced-deployment-
  patterns and practical-tuning notes) recommending it; continues to reinforce the
  existing pack-request rather than adding a new one.
