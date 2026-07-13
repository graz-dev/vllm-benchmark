<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Load-Testing Tools & Methodology for LLM Inference

**Source:** [GuideLLM GitHub](https://github.com/vllm-project/guidellm),
[GuideLLM — Red Hat Developer](https://developers.redhat.com/articles/2025/06/20/guidellm-evaluate-llm-deployments-real-world-inference),
[vllm bench serve — vLLM docs](https://docs.vllm.ai/en/latest/cli/bench/serve/),
[vllm/benchmarks/benchmark_serving.py](https://github.com/vllm-project/vllm/blob/main/benchmarks/benchmark_serving.py),
[LLM Inference Benchmarking: Fundamental Concepts — NVIDIA Technical Blog](https://developer.nvidia.com/blog/llm-benchmarking-fundamental-concepts/),
[ai-dynamo/aiperf GitHub](https://github.com/ai-dynamo/aiperf),
[GenAI-Perf — NVIDIA Triton docs](https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/perf_analyzer/genai-perf/README.html),
[Load Testing LLM Applications: Why k6 and Locust Lie to You](https://tianpan.co/blog/2026-03-19-load-testing-llm-applications),
[LLM Locust — TrueFoundry](https://www.truefoundry.com/blog/llm-locust-a-tool-for-benchmarking-llm-performance)
**Date distilled:** 2026-07-13

## Problem addressed

This repo's studies use GuideLLM as load generator (`ROADMAP.md` Q2 already flags
NVIDIA's GenAI-Perf/AIPerf as an alternative under evaluation). Different load-testing
tools measure TTFT/ITL/throughput differently and generate load differently — comparing
raw numbers across tools (or across studies that used different tools) without
accounting for this is a methodological trap. This note distills how the main options
actually work under the hood.

## Levers / parameters touched

Load-generation model (open-loop vs. closed-loop / fixed-concurrency), arrival-time
distribution (Poisson, gamma/burstiness, constant-rate), and each tool's exact TTFT/
ITL/throughput measurement formula and scoping window.

## Key results

- **GuideLLM**: open-loop generator (arrivals scheduled independently of server
  responses). `rate-type` modes: `synchronous` (sequential), `concurrent` (fixed
  parallel streams — closed-loop-like backpressure), `throughput` (no rate cap, finds
  max capacity), `constant` (fixed req/s, async, true open-loop), `poisson` (stochastic
  Poisson-distributed arrivals around a mean rate), `sweep` (ramps rate to map the
  latency/throughput curve). TTFT = time to first streamed token; ITL = mean time
  between consecutive output tokens, excluding the first.
- **NVIDIA GenAI-Perf / AIPerf** (AIPerf is GenAI-Perf's successor, now under
  `ai-dynamo/aiperf`): defines ITL/TPOT as `(e2e_latency − TTFT) / (total_output_tokens
  − 1)` — the `−1` explicitly excludes the first token to isolate pure decode time from
  prefill. Keeps N concurrent requests active *continuously* throughout a test
  (fixed-concurrency, closed-loop-style) — unlike LLMPerf, which sends batches with a
  "draining" gap where concurrency drops to zero between batches, a real source of
  cross-tool incomparability. Scopes throughput (TPS) strictly from first-request-sent
  to last-response-received, whereas LLMPerf includes harness overhead (prompt prep,
  response storage) in the same denominator — can inflate LLMPerf's reported duration by
  up to ~33% at low concurrency. Distinguishing features GuideLLM lacks: native
  multi-turn conversation simulation with turn-level metrics, built-in embeddings/
  ranking/RAG endpoint support (not just chat completions), GPU telemetry alongside
  client-side metrics, and "timeslice" (temporal, not just aggregate) reporting.
- **vLLM's own `benchmark_serving.py` / `vllm bench serve`**: also open-loop —
  `--request-rate` (req/s, or `inf` for max-throughput mode at t=0); arrivals follow a
  Poisson process by default, or a **gamma distribution when `--burstiness` is set**
  (burstiness <1 = burstier/clustered arrivals, >1 = more uniform spacing) — this
  burstiness knob has no equivalent in GuideLLM's or AIPerf's simpler poisson/constant
  split. `--max-concurrency` layers a closed-loop-style cap on top to emulate an
  upstream gateway limiting in-flight requests. It's the reference implementation the
  other tools calibrate against, but is a single script with less structured
  sweep/reporting tooling than GuideLLM or AIPerf, and lacks AIPerf's multi-turn/
  embedding/GPU-telemetry features.
- **Generic tools (k6, Locust)**: built for atomic request/response HTTP — no native
  TTFT or per-token-ITL capture (requires timing each streamed chunk, which neither does
  out of the box). Locust has a documented **GIL bottleneck**: CPU-bound token-timing
  work on the client competes with its event loop, so under concurrency the *client*
  becomes the bottleneck and reports inflated ITL that looks like server degradation but
  isn't (multi-process Locust workarounds close this gap). k6 (Go, natively
  multi-threaded) avoids the GIL issue but still needs custom instrumentation for TTFT/
  ITL semantics. Purpose-built wrappers (e.g. "LLM Locust") bolt on streaming-aware
  timing where needed.

## Implications for vLLM/k8s tuning

- **Two compounding pitfalls when comparing numbers across tools/studies**: (1)
  differing TTFT/ITL/TPS formulas and scoping windows (e.g. GenAI-Perf/AIPerf's
  first-request-to-last-response scoping vs. LLMPerf including harness overhead; the
  `−1` denominator convention for ITL isn't universal) mean raw numbers aren't
  comparable without checking each tool's exact formula; (2) **open-loop vs.
  closed-loop divergence under saturation** — fixed-concurrency modes cap in-flight
  requests so per-request latency can look artificially stable even as the server
  queues internally, while true open-loop (Poisson/constant-rate) exposes
  queueing-driven TTFT blowup as arrival rate nears capacity. Comparing a
  `concurrent`-mode GuideLLM run against an open-loop `constant`/`poisson` run (or
  against AIPerf's fixed-N-concurrent design) "at the same load" is comparing different
  things.
- **Actionable for this repo**: every study's README should record which tool, which
  rate-type/concurrency mode, and (if comparing across studies) each tool's TTFT/ITL
  formula — `studies/0-explorative` already documents its exact GuideLLM invocation
  (`--rate-type throughput --max-seconds 900`), which is the right level of detail; keep
  doing this for every future study, especially if/when GenAI-Perf/AIPerf gets adopted
  per `ROADMAP.md` Q2, since its concurrency model and ITL formula genuinely differ from
  GuideLLM's.
- If a future study needs to simulate bursty, non-uniform real-world traffic rather
  than steady-state throughput (this repo's current `throughput` rate-type finds a
  ceiling, not a realistic arrival pattern), vLLM's own `benchmark_serving.py`
  `--burstiness` parameter or GuideLLM's `poisson` rate-type are the mechanisms to reach
  for — `sweep` (GuideLLM) is the right choice for mapping a full latency/throughput
  curve rather than a single operating point.

## Which Akamas parameters to explore

N/A — none of this is a vLLM/Akamas-tunable parameter; it's a load-generator/
methodology choice made at the workflow level (this repo's `k8s/run_test_throughput.sh`
task), not inside `parametersSelection`. Directly resolves part of `ROADMAP.md`'s open
question **Q2** (load-generator choice) — worth updating Q2 with the concrete
measurement-methodology differences found here (concurrency model, ITL formula) next
time that question is revisited, rather than treating it as purely "which tool is
better."
