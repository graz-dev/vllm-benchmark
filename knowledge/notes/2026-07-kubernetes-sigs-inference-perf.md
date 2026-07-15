<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# kubernetes-sigs/inference-perf — Load-Testing Tool with Real-Dataset Replay

**Source:** https://github.com/kubernetes-sigs/inference-perf (README, `deploy/README.md`,
and `docs/{loadgen,config,metrics,conversation_replay,design,goodput,cli_flags}.md`).
**Date distilled:** 2026-07-14

## Problem addressed

Evaluates a third load-generator option against the two already covered in
`knowledge/notes/2026-07-llm-inference-load-testing-tools.md` (GuideLLM, currently used
by this repo's studies; NVIDIA GenAI-Perf/AIPerf, evaluated as an alternative) —
specifically to check whether it closes a gap neither of those two tools does: every
study run so far uses GuideLLM's synthetic fixed-shape prompts, which can't produce
realistic prefix-cache hit rates or content-dependent load behavior.

## Levers / parameters touched

Load-generator tool choice and configuration: load model (open-loop `constant`/`poisson`
vs. closed-loop `concurrent` vs. saturation sweep), `data.type` (prompt/dataset source),
and metric selection (TTFT/TPOT/ITL/Goodput).

## Key results

- **Maturity**: `kubernetes-sigs` project under `wg-serving`, created Jan 2025, actively
  developed (7 tagged releases through v0.6.0 as of Jun 2026, pushed as recently as the
  day before this note was written). Pre-1.0 versioning and 107 open issues signal
  continued API churn is likely, but no explicit "not production ready" framing found.
- **Load model — the only one of the three tools with both modes**: open-loop
  (`constant`/`poisson`, matching GuideLLM's model) *and* closed-loop (`concurrent`,
  matching AIPerf's model), plus automatic saturation sweeps (linear/geometric rate
  progression until the server saturates) and multi-stage ramps — neither GuideLLM nor
  AIPerf (as previously evaluated) supports ramping/sweeping natively.
- **Dataset/prompt realism — the decisive difference**: native support for real datasets
  (ShareGPT, CNN/DailyMail, BillSum, Infinity Instruct, VisionArena for images) and real
  **production trace replay** (Azure LLM Inference trace format — arrival timing + token
  counts; full OpenTelemetry trace/DAG replay, reconstructing dependent/parallel call
  graphs from captured spans while substituting live model output for recorded turns).
  Also ships a `shared_prefix` generator (explicit shared-prefix groups, purpose-built
  for prefix-cache-hit-rate testing) and a `conversation_replay` generator (parameterized
  synthetic multi-turn conversations with a shared system prompt). This is the specific
  capability neither GuideLLM's synthetic fixed-shape prompts nor AIPerf (as previously
  evaluated) are documented to have.
- **Metrics**: TTFT, TPOT (`(e2e_latency − TTFT) / (output_tokens − 1)` — same formula as
  AIPerf's TPOT/ITL, per the existing note), a separately-tracked true per-token ITL,
  Normalized TPOT, input/output/request throughput, and **Goodput** (SLO-constrained
  throughput, configurable via config or per-request headers) — a metric not documented
  for either GuideLLM or AIPerf in the existing note.
- **Kubernetes-native integration is less special than the project name implies**: runs
  as a plain Kubernetes Job (manifest + ConfigMap, optional Helm chart) — architecturally
  identical to how GuideLLM runs in this repo's studies today. No integration with the
  Gateway API Inference Extension (`InferencePool`/`InferenceObjective`) despite the
  `kubernetes-sigs` affiliation.
- **Backend compatibility**: README states verified support for vLLM, SGLang, and TGI,
  "easily extensible to any OpenAI-compatible endpoint" — but `docs/config.md`'s inline
  comment on `server.type` says "Currently only vLLM supported," an unresolved doc
  inconsistency (not a concern for this repo, which only ever targets vLLM either way).
- **Limitations found**: streaming must be explicitly enabled (`api.streaming: true`) to
  get TTFT/ITL/TPOT at all — same constraint GuideLLM/AIPerf share, not a new gap. Azure
  trace replay only supports the `random` data generator for token-count matching (can't
  combine real arrival timing with a different content source in one run). No
  model-aware validation for multimodal configs (a per-model capability registry is
  tracked as future work, per its own docs).

## Implications for vLLM/k8s tuning

- **Directly actionable for this repo**: since it deploys as a drop-in Kubernetes Job
  replacement for GuideLLM (no workflow-architecture change needed), it's a low-risk tool
  to trial. The realistic-dataset gap it closes is exactly the kind of thing that could
  change which vLLM configuration wins an Akamas study — a configuration that looks best
  under GuideLLM's synthetic fixed-shape prompts might not be the same one that wins
  under ShareGPT-driven traffic with real prefix-cache reuse, since `0-explorative`'s own
  winning config (`FLASHINFER`+`fp8_e4m3`) was found entirely under synthetic load.
- **Any future study using this tool must record, per Q2's existing rule**: which tool,
  which load mode (open/closed-loop), and which `data.type` — comparing a GoodPut-based
  result against a raw-throughput result from a different tool would be as invalid as
  comparing GuideLLM against AIPerf's differing concurrency models already is.
- **The doc inconsistency on `server.type` should be confirmed directly against the CLI/
  source before a study relies on it** — low risk here since this repo only ever targets
  vLLM, but worth a one-line note in whichever study first adopts this tool.

## Which Akamas parameters to explore

N/A — this is a load-generator tool choice, not a tunable Akamas parameter. Directly
informs `ROADMAP.md`'s Q2 (load generator choice) and Section D's study #6 (load
generator validation: GuideLLM vs. inference-perf), which trials this tool with
ShareGPT replay against the same vLLM configuration space as `0-explorative` before any
wider adoption decision.
