<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Triton Model Analyzer

**Source:** [triton-inference-server/model_analyzer (GitHub)](https://github.com/triton-inference-server/model_analyzer) + [docs/config.md](https://github.com/triton-inference-server/model_analyzer/blob/main/docs/config.md)
**Date distilled:** 2026-07-08

## Problem addressed

An NVIDIA-maintained CLI tool that automatically searches a Triton Inference Server
model's configuration space (batch size, dynamic batching, instance/replica count, and —
in its fuller modes — the whole model config) to find configurations meeting throughput/
latency/memory objectives, instead of manual trial and error. Conceptually the closest
thing in this knowledge base to what Akamas itself does (automated search over serving
config against objectives/constraints), but scoped to Triton-served models rather than a
general optimization platform — most directly relevant as a **design-pattern reference**
for how to structure objectives/constraints, not as a tool this repo would run directly
unless a study's stack actually serves through Triton.

## Levers / parameters touched

- **Search mode** (`run_config_search_mode`): `brute` (exhaustive over defined
  dimensions), `quick` (heuristic hill-climbing, sparse exploration for speed), or
  `optuna` (alpha; hyperparameter-optimization-framework-based search over virtually the
  entire model config, not just the three headline dimensions).
- **Core three dimensions** searched by brute/quick modes: `max_batch_size`, dynamic
  batching (`max_queue_delay_microseconds`), and `instance_group` (replica count per
  GPU, e.g. `kind: KIND_GPU, count: [1, 2]`). Manual/Optuna modes extend to the full
  Triton model config.
- **Load-generation sweep parameters**: `--batch-sizes`, `--concurrency` (supports a
  `start`/`stop`/`step` range), `--request-rate`.
- **Constraints** (hard filters, e.g. `perf_latency_p99: {max: 100}`,
  `gpu_used_memory: {max: 200}`, `perf_throughput: {min: 5}`) — configurations violating
  a constraint are filtered out rather than merely scored lower.
- **Objectives** (what's optimized, optionally weighted, e.g.
  `objectives: {perf_latency_p99: 2, perf_throughput: 3}`).
- **LLM-specific metrics already built in**: `output_token_throughput`,
  `inter_token_latency_p99`, `time_to_first_token_p99` — confirming Triton Model
  Analyzer is already used for LLM-serving workloads, not just generic ML models,
  alongside generic ones (`perf_throughput`, `perf_latency_p99`, `gpu_used_memory`,
  `gpu_free_memory`, `gpu_utilization`, `cpu_used_ram`, `cpu_free_ram`).

## Key results

- This is a tool/config-schema doc, not a benchmark paper — there are no throughput/
  latency numbers to extract; the "key results" here are the concrete config vocabulary
  and defaults, useful as a reference schema:
  - Default search bounds: `run_config_search_min_concurrency=1`,
    `run_config_search_max_concurrency=1024`,
    `run_config_search_min_model_batch_size=1`,
    `run_config_search_max_model_batch_size=128`.
  - Output is CSV-based (`metrics-model-inference.csv`, `metrics-model-gpu.csv`,
    `metrics-server-only.csv`) plus generated summary/detailed report tables.

## Implications for vLLM/k8s tuning

- **Conditional applicability**: this tool only helps directly if a study's model is
  actually served through Triton Inference Server (e.g. via Triton's vLLM backend) —
  this repo's studies so far target vLLM's own OpenAI-compatible server directly, not
  Triton, so Model Analyzer isn't a drop-in replacement for Akamas here. Flag this
  explicitly before recommending it for a specific study; verify the study's actual
  serving stack first.
- **Reusable design pattern regardless of tool**: the objectives (optionally weighted)
  + constraints (hard min/max filters) split maps directly onto how an Akamas study's
  `goal` should be structured — a useful cross-check when writing a study's `goal.yaml`
  via the `akamas-study-manager` plugin: are the SLO-type requirements (e.g. "TTFT p99 under
  Xms") expressed as hard constraints, and is the thing actually being searched for
  (throughput, cost) the weighted objective? This tool's schema is a second independent
  confirmation of that split (Akamas's own study format already separates objective from
  constraints) rather than a new idea, but useful validation.
- The **`quick` heuristic search mode** (sparse hill-climbing vs. brute-force
  exhaustive) is conceptually similar to how Akamas's own optimization algorithms
  (Bayesian optimization etc.) already avoid exhaustive search — not a new lever for this
  repo, since Akamas's search strategy is chosen at the study/workflow level already, but
  confirms sparse/heuristic search over an exhaustive grid is the standard industry
  approach for this class of problem, reinforcing that Akamas studies here shouldn't
  need unreasonably large step counts to converge.
- Its **instance-group / replica-count dimension** is the same "replica count as a
  tunable" gap already identified in "Mind the Memory Gap"
  (`knowledge/notes/2026-07-gpu-memory-bound-large-batch-inference.md`) and H4/backlog
  #4 — another independent confirmation that replica count is a standard axis to search,
  not a novel idea specific to this repo's own hypotheses.

## Which Akamas parameters to explore

- No new vLLM/GPU parameters — Triton Model Analyzer's three headline dimensions
  (max batch size, dynamic-batching queue delay, instance/replica count) map onto
  concepts already tracked in this knowledge base (`vLLM.max_num_seqs`/
  `max_num_batched_tokens` for batching, and the still-missing Kubernetes replica-count/
  HPA parameter already logged against H4/backlog #4 — this doesn't add a new pack
  request, it's the same one).
- If a future study's stack does serve vLLM behind Triton (not the case for any study so
  far per this repo's studies), Model Analyzer's LLM-specific metric names
  (`time_to_first_token_p99`, `inter_token_latency_p99`, `output_token_throughput`) would
  be a useful naming cross-reference when defining that study's telemetry `metrics:`
  list — but this is speculative until such a study exists; don't add a pack request for
  it now.
