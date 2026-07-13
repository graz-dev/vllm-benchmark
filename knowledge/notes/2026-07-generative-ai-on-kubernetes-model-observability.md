<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Generative AI on Kubernetes — Model Observability: Metrics, Naming, and Tracing

**Source:** *Generative AI on Kubernetes: Operationalizing Large Language Models* by
Roland Huß and Daniele Zonca (O'Reilly, 2026), Chapter 5 "Model Observability"
(`knowledge/sources/Generative AI on Kubernetes.pdf`, pages 153-171 only — see scope
note below).
**Date distilled:** 2026-07-13

## Scope note

This chapter has two halves: **infrastructure/model-server observability** (logs,
Prometheus metrics, OpenTelemetry tracing, GPU metrics) and **model quality/safety**
(hallucination detection, guardrails, responsible AI — NeMo Guardrails, FMS Guardrails
Orchestrator/TrustyAI, Guardrails AI, Llama Stack's Safety API). Only the first half is
distilled here — model quality/safety doesn't fit any of this knowledge base's four
in-scope categories (parameter tuning, serving tooling, load testing, k8s infra) and is
a different concern (correctness/safety, not performance) from what this repo's Akamas
studies optimize for. Flagging its existence here in case a future study ever needs a
quality *constraint* (e.g. a `goal.constraints` gate on a hallucination-rate metric) —
but not distilling the guardrails frameworks themselves.

## Problem addressed

This repo's own `studies/0-explorative` already has a Prometheus telemetry instance
tracking metrics named `vLLM.prefill_token_throughput`, `vLLM.time_to_first_token_avg`,
etc. This chapter reveals the **actual underlying vLLM Prometheus metric names** these
Akamas metric identities must map to, plus the competing OpenTelemetry semantic-
convention names — useful for verifying this repo's own telemetry config is pointed at
the right underlying metric, and for tracing/debugging a study's Prometheus setup
directly against vLLM's own `/metrics` endpoint.

## Levers / parameters touched

Not vLLM CLI flags — observability configuration: which metrics to scrape/name, log
verbosity (`--disable-log-requests`), and how to wire tracing (`--otlp-traces-endpoint`,
`OTEL_SERVICE_NAME`).

## Key results

- **Confirmed vLLM Prometheus metric names** (directly checkable against this repo's
  own telemetry setup):
  - `vllm:time_to_first_token_seconds` — TTFT, a histogram, seconds.
  - `vllm:time_per_output_token_seconds` — TPOT/inter-token latency, histogram, seconds.
  - `vllm:e2e_request_latency_seconds` — full-response latency, histogram, seconds.
  - `vllm:prompt_tokens_total` / `vllm:generation_tokens_total` / `vllm:tokens_total` —
    input/output/combined token throughput counters.
  - `vllm:num_requests_waiting` / `vllm:num_requests_running` — queue-depth metrics
    (this repo's own `0-explorative` study already tracks the equivalents).
  - OpenTelemetry's competing semantic-convention names for the same concepts:
    `gen_ai.server.time_to_first_token`, `gen_ai.server.time_per_output_token`,
    `gen_ai.server.request.duration` — **OpenTelemetry has no equivalent recommendation
    for the throughput metric**, so vLLM's own naming is the only convention there.
  - `--disable-log-requests` turns off vLLM's per-request prompt/parameter log line
    (relevant for this repo if log volume or prompt-content logging is ever a concern
    during a load test).
- **KServe's metric-aggregation gap**: in **Knative** deployment mode, a pod runs
  multiple sidecar containers (Istio/Knative proxy + the model server), and Prometheus
  by default only scrapes one endpoint per pod — KServe's own `qpext` component
  aggregates metrics from all containers into a single scrapeable endpoint
  (`serving.kserve.io/enable-metric-aggregation` annotation). **Not needed in Standard
  mode** (single container per pod) — which is what this repo's studies use, so this
  gap doesn't apply here, but is worth knowing if a future study adopts KServe Knative
  mode.
- **Tracing**: OpenTelemetry is the de facto standard (not natively built into
  Kubernetes); vLLM has native OpenTelemetry SDK integration
  (`--otlp-traces-endpoint`, `OTEL_SERVICE_NAME` env var), commonly exported to Jaeger.
  Distinct from metrics: traces are **pushed** by each component (not pulled/scraped
  like Prometheus) and require every component in a request's path (gateways,
  firewalls, the model server) to propagate the same trace identifier to be useful.
- **GPU metrics are vendor-specific tooling, no common naming convention across
  vendors**: NVIDIA's DCGM Exporter (Helm-chart deployable, integrates with the GPU
  Operator), AMD's Device Metrics Exporter, Intel's Prometheus Metric Exporter — all
  expose vendor-specific low-level metrics (PCIe bandwidth, graphics-engine activity)
  as Prometheus-compatible endpoints, but naming isn't standardized across vendors.
- **SLI/SLO/SLA framing applied to LLM metrics**: the book's own example ties TPOT
  directly to an SLI/SLO (e.g., "commit to keeping TPOT below a threshold in 99.999%
  of requests, monthly") — a concrete pattern for turning a raw metric into an
  operational commitment, distinct from (and complementary to) using the same metric
  as an Akamas goal/constraint.

## Implications for vLLM/k8s tuning

- **Direct, checkable cross-reference for this repo's telemetry config**: the exact
  vLLM metric names above (`vllm:time_to_first_token_seconds`,
  `vllm:num_requests_waiting`, etc.) are what this repo's Prometheus telemetry instance
  ultimately scrapes underneath the `vLLM.*` Akamas metric identities — worth a
  one-time check that `studies/0-explorative/akamas/telemetry/prometheus.yaml`'s
  metric mappings actually point at these real vLLM metric names (inherited from the
  pre-restructure setup per this study's own README, not independently re-verified
  against a live vLLM `/metrics` endpoint at the time it was set up).
- **This repo's current studies don't need KServe's `qpext` aggregation** (Standard/
  manual-Deployment mode, one container per pod) — confirms no telemetry gap exists
  from this specific cause; worth remembering if a future study adopts KServe Knative
  mode instead.
- **Tracing (OpenTelemetry/Jaeger) is not currently used by this repo's studies** —
  they rely on Prometheus metrics + `kubectl logs` only. Not needed for the current
  throughput-optimization use case, but would matter if a future study needs to
  correlate a specific slow request across multiple hops (e.g. a disaggregated
  prefill/decode setup, or an AI Gateway in front of vLLM).

## Which Akamas parameters to explore

N/A — this is observability/telemetry configuration, not a tunable vLLM parameter.
Directly informs how any study's `telemetry-instance`/metric mappings should be
verified against vLLM's actual Prometheus metric names, and could inform a future
`ROADMAP.md` Q-item about confirming this repo's telemetry config's metric-name
mappings are accurate (currently inherited from a pre-restructure setup, not
independently re-verified) — flagged as a possible addition, not added here.
