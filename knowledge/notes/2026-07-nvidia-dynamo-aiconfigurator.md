<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# NVIDIA Dynamo: Finding Best Initial Configs (AIConfigurator)

**Source:** [NVIDIA Dynamo v0.8.1 docs — Finding best initial configs](https://docs.nvidia.com/dynamo/v-0-8-1/user-guides/finding-best-initial-configs)
**Date distilled:** 2026-07-08

## Problem addressed

Documents `aiconfigurator`, a CLI/webapp tool bundled with NVIDIA's Dynamo project that
searches deployment **topology** — aggregated vs. disaggregated serving, prefill/decode
worker counts, tensor/pipeline parallelism degree, total GPU count and GPU type — to hit
a given TTFT/TPOT SLA for a named model, using a pre-built performance database rather
than live benchmarking. Framed as replacing hours of manual profiling with a 20–30 second
lookup/search. This is a tool doc, not a research finding, and it operates one level
above per-instance vLLM parameter tuning — directly relevant to the topology-planning gap
already flagged across the distributed-inference note series
(`knowledge/notes/2026-07-distributed-inference-scaling-dimensions.md` and its two
follow-ups) as not covered by anything Akamas currently models.

## Levers / parameters touched

- **Aggregated vs. disaggregated architecture** — the tool evaluates both and reports
  which wins for the given workload/SLA rather than requiring the user to decide upfront.
- **Prefill/decode worker counts** — sized independently once disaggregation is chosen.
- **Tensor parallelism (TP) and pipeline parallelism (PP) degree.**
- **Total GPU count and GPU type/generation** (`--system`, e.g. `h200_sxm`, `h100_sxm`).
- **Workload shape as input, not output**: input sequence length (ISL) and output
  sequence length (OSL) in tokens, plus target TTFT (ms) and TPOT (ms) — these are the
  SLA/workload constraints the search satisfies, not parameters it varies.
- Supported model families (must be in its pre-profiled database): GPT, LLAMA2/3,
  QWEN2.5/3, Mixtral, DEEPSEEK_V3. Supported GPUs: H100, H200, A100, B200 (preview), GB200
  (preview).
- Output: a ranked config (e.g. a `disagg/top1` result) plus a ready-to-deploy Kubernetes
  YAML manifest — the tool's endpoint is a deployable topology, not just a recommendation.

## Key results

- Example run: `QWEN3_32B`, 32×H200, ISL=4000, OSL=500, target TTFT=300ms, target
  TPOT=10ms → found config reaches **812.92 tokens/s/gpu**, 120.23 tokens/s/user, meeting
  TTFT 276.76ms and TPOT 8.32ms — and the disaggregated result is reported as **1.70×**
  better throughput than the aggregated alternative for this specific model/hardware/SLA
  combination. The 1.70× figure is specific to this exact config, not a general
  disaggregation-vs-aggregation multiplier — don't generalize it.
- A second example (`QWEN2.5_7B`, 8 GPUs, TTFT=100ms, TPOT=5ms target) is cited as a
  "strict SLA" scenario, illustrating the tool handles both large (32B+) and small (7B)
  models, but no output numbers are given for it in what was extracted.
- Core speed claim: "20–30 seconds vs. hours" — this is a lookup/simulation against a
  pre-profiled performance database, not a live benchmark run on real hardware; treat its
  output as a strong starting-point estimate to validate with real load testing, not as a
  substitute for it.

## Implications for vLLM/k8s tuning

- This tool is a plausible **answer to the topology-planning gap** repeatedly flagged in
  this knowledge base: parts 1–3 of the distributed-inference series established that
  disaggregation, TP/PP/EP/DP choice, and worker counts sit above what Akamas's installed
  vLLM pack models (see `ROADMAP.md`'s pack-request debt item) — `aiconfigurator` is a
  purpose-built tool for exactly that layer, complementary to (not competing with) an
  Akamas study. A workable division of labor: use `aiconfigurator` (or equivalent manual
  reasoning) to pick a topology (aggregated/disaggregated, TP/PP degree, GPU count) before
  scaffolding a study, then let Akamas optimize the per-instance vLLM parameters
  (`gpu_memory_utilization`, `max_num_seqs`, etc.) within that fixed topology — matches
  how this repo's studies are currently scoped (single-instance parameter tuning, fixed
  topology decided beforehand).
- Coverage is limited to its pre-profiled model/GPU database — if a study's actual
  model or GPU isn't in that list (GPT/LLAMA/Qwen/Mixtral/DeepSeek-V3 families; H100/
  H200/A100/B200/GB200), the tool's output doesn't apply and topology would need to be
  decided by other means (the distributed-inference series' manual guidance, or direct
  profiling).
- The tool's own output is described as a starting point, meeting SLA targets in its
  simulated estimate — this repo's practice of validating everything with real load
  tests (GuideLLM per `ROADMAP.md` Q2) is still necessary even if a future workflow
  adopts `aiconfigurator` for initial topology selection.

## Which Akamas parameters to explore

- None directly — `aiconfigurator` operates on deployment topology (aggregated/
  disaggregated, TP/PP degree, worker count, GPU count/type), which this knowledge base
  has already established isn't represented in the installed vLLM optimization pack's
  parameter list (confirm with `akamas describe optimization-pack vLLM` or the pack's own
  repo, https://gitlab.com/akamas/optimization-packs/vllm). This
  note doesn't add a new pack-request item — it's the same topology gap already logged in
  `ROADMAP.md`'s pack-request debt item, just now with a candidate external tool that
  could fill it *without* needing pack support, by deciding topology before a study
  starts rather than asking Akamas to search it.
- Once a topology is fixed via a tool like this, `vLLM.tensor_parallel_size` would
  typically be pinned rather than searched (the topology decision already set it) —
  worth noting as a possible alternative to H5's "let Akamas search a narrowed TP domain"
  framing: if topology is decided externally, TP may not need to be an Akamas
  `parametersSelection` entry at all for that study.
