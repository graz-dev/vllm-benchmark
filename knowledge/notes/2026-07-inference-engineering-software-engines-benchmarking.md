<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Inference Engineering — Inference Engine Choice, NVIDIA Dynamo, and Benchmarking/Profiling Tooling

**Source:** *Inference Engineering* by Philip Kiely (Baseten Books, 2026), Chapter 4
"Software" (`knowledge/sources/Inference Engineering.pdf`, printed pages 93-115).
**Date distilled:** 2026-07-13

## Scope note

The chapter's CUDA/kernel-level sections (4.1: CUDA kernels, cuBLAS/CUTLASS/CuTe/
FlashInfer, kernel fusion) and deep-learning-framework sections (4.2: PyTorch,
`torch.compile`, safetensors/ONNX, `transformers`/`diffusers`) are background context
below the level this repo ever configures directly — summarized only briefly below,
since this repo works at the vLLM-flag level, not the CUDA-kernel level. The
NVIDIA Dynamo section (4.4) mostly reinforces two notes already in this knowledge base
(`2026-07-nvidia-dynamo-aiconfigurator.md`, `2026-07-nvidia-dynamo-planner.md`) rather
than adding new findings — flagged as confirmation, not repeated in full.

## Problem addressed

Compares the three production inference engines (vLLM, SGLang, TensorRT-LLM) head to
head for the first time in this knowledge base — every existing note assumes vLLM
without comparing it against the alternatives this repo could have chosen instead — and
adds benchmarking/profiling tooling this repo hasn't previously logged (Locust,
NVIDIA GenAI-Perf, SGLang Genai-bench, PyTorch Profiler, NVIDIA Nsight Systems/Compute).

## Levers / parameters touched

Not vLLM parameters — inference-engine selection (vLLM vs. SGLang vs. TensorRT-LLM) and
benchmarking/profiling tool selection, both platform choices made before a study starts,
not something Akamas tunes.

## Key results

- **Inference engine comparison** (the book's own summary table): vLLM — good
  performance, easiest to adopt, broadest model/hardware support (NVIDIA, AMD, Intel,
  Google TPU), Apache 2.0. SGLang — good performance, easy to adopt, strong day-zero
  support for MoE models specifically (works closely with DeepSeek/Qwen/Kimi/Z AI on
  optimized implementations), invested in large-scale multi-node MoE deployments
  (GB200 NVL72). TensorRT-LLm — best raw performance, hardest to use, NVIDIA-only
  hardware, access to closed-source hand-fused kernels for Hopper/Blackwell and
  NVIDIA-specific number formats (NVFP4); has two incompatible major-version lines (V0 =
  TensorRT plugin, V1 = standalone PyTorch-based, released summer 2025 — always confirm
  which version a deployment uses before assuming a flag/feature is available). The
  author's own explicit guidance: use vLLM when you want a model server that performs
  well out of the box for almost any open model, or need multimodal ("Omni") support;
  use SGLang for MoE-heavy throughput or wanting deep engine customization; use
  TensorRT-LLM when running a well-supported architecture on Hopper+ hardware and
  willing to invest extra engineering effort for the best possible performance.
- **NVIDIA Dynamo — direct confirmation of when NOT to adopt it**: "many deployments
  don't need the additional complexity of Dynamo... unless you're operating with enough
  volume for disaggregation and KV-aware routing to matter, Dynamo will be unnecessary
  work and excess overhead. In these cases, you can use inference engines directly." This
  directly confirms this repo's existing conclusion (from the two prior Dynamo notes)
  that Dynamo/llm-d-style orchestration is N/A for single-replica studies — now stated
  explicitly by a third independent source, not just inferred.
- **Benchmarking methodology, new to this knowledge base**: the strongest possible
  benchmark **shadows real production traffic** onto the system under test (copying live
  requests without affecting the original response) — not something this repo can do
  (no production traffic exists), but frames synthetic load generation (GuideLLM, per
  existing notes) as the fallback, not the ideal. Four dimensions any synthetic-traffic
  simulation must match to be trustworthy: input/output sequence lengths (drives TTFT
  and memory), volume/pattern of concurrent traffic (drives batching behavior), request
  *content* (drives cache-hit-rate and speculative-decoding draft-acceptance rate — not
  just token count), and inference parameters (temperature, reasoning effort — set to
  actual production values, not benchmark-convenient ones). New tools not previously
  logged: **SGLang Genai-bench** (CLI+dashboard, works with any inference framework, not
  just SGLang), **NVIDIA GenAI-Perf** (already logged in the load-testing note, this adds
  the "client-side" framing), **Locust** (general-purpose load testing, not LLM-specific,
  can simulate millions of simultaneous users). A genuinely new idea: **using an eval
  dataset (MMLU, gsm8k, SWE-bench, HumanEval) as benchmark request content**, not just
  for quality checking — realistic prompt *distributions* matched to the target
  workload, and a way to spot-check that a performance optimization hasn't silently
  degraded output quality (e.g. from an overly aggressive speculative-decoding or
  quantization config) while measuring it.
- **Benchmarking discipline**: consistent configuration + one-variable-at-a-time changes
  applies to benchmark methodology itself, not just to the system under test — directly
  matching this repo's own reliance on Akamas' controlled-experiment methodology, though
  stated here as a general practice rather than Akamas-specific.
- **Profiling vs. benchmarking, a distinction this knowledge base hadn't previously
  drawn**: benchmarking answers "how is my system performing" (a single number, e.g. P90
  TTFT); profiling answers "why" (where the milliseconds went). Named tools: **PyTorch
  Profiler** (step-by-step CPU/GPU time + memory, easiest to use), **NVIDIA Nsight
  Systems** (system-wide, multi-GPU interconnect tracing — the same tool already named in
  the training-job-observability note from the other book, confirming it's not
  training-specific), **NVIDIA Nsight Compute** (per-CUDA-kernel compute/memory
  analysis, the most granular). Author's own guidance: most inference engineers using an
  already-optimized engine (vLLM/SGLang/TensorRT-LLM) don't need profiling day-to-day —
  it's a tool for contributing to the engine itself or debugging a genuinely unexplained
  performance gap, not routine tuning.

## Implications for vLLM/k8s tuning

- **Validates this repo's existing engine choice (vLLM) as reasonable for its own stated
  use case** — broad model/hardware support, easiest to adopt — rather than a gap.
  Switching to SGLang would only make sense if this repo ever serves a large MoE model at
  high multi-node throughput (not the current dense single-GPU case); switching to
  TensorRT-LLM would only make sense chasing maximum performance on Hopper+ hardware
  specifically, at the cost of a harder-to-use `config.yaml`-based workflow-integration
  surface than vLLM's flag-based one Akamas already models cleanly. No action needed —
  this is a confirmation, not a gap to close.
- **Strengthens (doesn't change) the existing Dynamo/llm-d conclusion**: three
  independent sources now agree Dynamo-style orchestration is unnecessary complexity
  below a certain scale/volume threshold this repo hasn't reached — no new
  `ROADMAP.md` action needed, the existing Q6/backlog #4 framing already covers this.
- **A genuinely new, actionable idea for this repo's own load-test design**: using an
  actual eval dataset's prompts (rather than purely synthetic/templated prompts) as the
  load generator's request content would make a study's cache-hit-rate and
  latency-percentile results more representative of real usage shape — worth
  considering the next time a study's `README.md` documents its load generator's prompt
  source, distinct from which *tool* (GuideLLM vs. others, already tracked in Q2).
- **Profiling (PyTorch Profiler / Nsight) is not currently used by any study** — matches
  this repo's existing reliance on Prometheus metrics + benchmark-level results only; not
  needed unless a future study hits an unexplained performance gap that metrics alone
  can't diagnose.

## Which Akamas parameters to explore

N/A — inference-engine selection, Dynamo adoption, and benchmarking/profiling tool
choice are all platform/methodology decisions made before or alongside a study, not
Akamas parameters. No new pack-request or `ROADMAP.md` hypothesis — the one candidate
addition (eval-dataset-as-load-content for more representative benchmarking) is a
methodology refinement worth a light mention under `ROADMAP.md`'s existing Q2
(load-generator choice) rather than a new Q-item — flagged for the user to confirm
before adding.
