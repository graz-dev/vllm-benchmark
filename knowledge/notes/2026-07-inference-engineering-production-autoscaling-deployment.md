<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Inference Engineering — Autoscaling, Cold Starts, Reliability, and Cost/Observability

**Source:** *Inference Engineering* by Philip Kiely (Baseten Books, 2026), Chapter 7
"Production" (`knowledge/sources/Inference Engineering.pdf`, printed pages 177-208).
**Date distilled:** 2026-07-13

## Scope note

Multi-cloud capacity management (7.3: hyperscaler/neocloud/reseller GPU procurement,
geo-aware load balancing, active-active/active-passive multi-region) and client-side
protocol details (7.5: WebSockets vs. gRPC, TLS handshake overhead) are background for
a single-cluster, single-region repo like this one — summarized only briefly, not
distilled in depth, since neither changes how this repo's studies are designed. Section
7.6 is a vendor pitch for Baseten's own platform, not distilled.

## Problem addressed

Covers the production-operations layer above a single vLLM instance: autoscaling
configuration knobs, what drives cold-start time (directly relevant to this repo's own
5-15 min per-experiment model-load cost, already flagged via the Run:ai Model Streamer
`ROADMAP.md` item), GPU hardware failure rates, and what to monitor in production —
extending, not duplicating, the existing autoscaling/multi-tenancy note.

## Levers / parameters touched

Not vLLM parameters — Kubernetes/platform-level autoscaling configuration (min/max
replicas, autoscaling window, scale-down delay, concurrency target), cold-start
optimization levers (image size, model-loading bandwidth, engine-compilation caching),
and observability metric selection.

## Key results

- **Five autoscaling configuration knobs**, more concrete than this knowledge base's
  existing autoscaling note: **min replicas** (floor, regardless of traffic), **max
  replicas** (ceiling), **autoscaling window** (sliding timeframe for scaling
  decisions), **scale-down delay** (grace period before removing replicas, trading
  cost against flapping/premature scale-down on spiky traffic), **concurrency target**
  (requests per replica before scaling up — must match the replica's actual batch-size
  configuration, or the autoscaler's model of capacity is wrong). Utilization-based
  scaling (GPU memory/compute) is a **lagging indicator**; traffic-based scaling
  (request count) can be proactive — recommended to combine both, since they don't
  always agree (e.g. LLM prefill: a few large-input requests can spike utilization far
  more than many small cached-hit requests, at the same request count).
- **Cold start, broken into four independently-optimizable factors**: GPU procurement
  (cloud-provider-dependent, a contract-negotiable factor), **image loading**,
  **model weight loading**, and **engine startup** (including any compilation time,
  e.g. TensorRT-LLM's engine-build step which can take minutes and should be cached
  rather than rebuilt per cold start). Two levers directly apply to this repo's own
  known model-load cost: (1) minimizing image size (only strictly necessary
  dependencies), and (2) **quantizing model weights also speeds up cold-start loading,
  not just inference** — a benefit not previously connected to the Run:ai Model
  Streamer item already in `ROADMAP.md`'s debt section, which only covered inference-
  time speed, not cold-start weight-loading speed specifically. Loading bandwidth
  matters concretely: loading from a third party (e.g. Hugging Face) is limited by their
  egress speed; loading from object storage near the GPU instance in the same datacenter
  is faster — this repo's own PVC-based model cache (per the earlier
  `2026-07-generative-ai-on-kubernetes-model-data-storage.md` note) is already the
  faster pattern, not the slow one.
- **Scale-to-zero, a clear decision heuristic not previously in this knowledge base**:
  requires both fast cold starts and robust request queueing as prerequisites. Good fit
  for periodic/scheduled traffic (business-hours-only agents, batch jobs); explicitly
  **not** a good fit for latency-sensitive apps with light, unscheduled traffic — the
  book's own framing: relying on scale-to-zero there "is probably a sign that your AI
  application is not yet ready for dedicated infrastructure and should use pay-per-token
  APIs until greater scale is reached." Not directly applicable to this repo (no
  production traffic, single fixed-duration experiments), but a useful heuristic if this
  repo's tooling is ever adapted to serve a lower-traffic internal use case.
- **GPU hardware failure rate, a concrete baseline number**: per Meta's own Llama 3
  paper (Grattafiori et al., 2024), 16,000 GPUs over 54 days experienced 419 unexpected
  interruptions — **roughly one failure per 50,000 GPU-hours**, primarily GPU-related
  (vs. network/host/dependency causes). A single 8-GPU node run for a year exceeds
  70,000 GPU-hours — "inference engineers should expect hardware failure" as a baseline
  expectation, not an edge case. Useful context for interpreting an unexplained
  experiment failure in a long-running study as possibly a hardware fluke rather than
  purely a parameter-caused crash, though this repo's studies run far below this scale
  (single GPU, short duration) so the base rate is a low-probability consideration here.
- **Observability checklist**: total request volume, request/response sizes (ISL/OSL),
  response code distribution (2XX/4XX/5XX), latency at P50/P90/P99, replica count
  (active + starting), utilization (CPU/host-memory/GPU/GPU-memory), and queue depth —
  explicitly framed as **interdependent**, not siloed (a latency spike could stem from
  request volume *or* long input sequences; seeing metrics together answers "why," not
  just "what"). Cross-references this repo's existing Q7 (verifying telemetry config
  metric-name accuracy) — this is the checklist of *categories* a study's telemetry
  should cover, distinct from Q7's question of whether the *names* are correct.
- **Cost estimation, two formulas for comparing per-token-API vs. dedicated-GPU
  economics**: per-token cost = `(input_tokens × price_per_million_in) +
  (output_tokens × price_per_million_out)`; dedicated cost = `total_gpu_hours ×
  price_per_gpu_hour`. Recommends estimating over at least a week to smooth usage
  variation, and including engineering time as part of total cost of ownership, not
  just GPU-hours. Not currently used by this repo (no cost-based Akamas goal formula
  exists), but directly relevant if backlog #3 (energy-efficiency study) is ever
  extended to a cost-efficiency framing instead of pure tokens/watt.

## Implications for vLLM/k8s tuning

- **Directly strengthens the Run:ai Model Streamer `ROADMAP.md` debt item** (added this
  session from Ch4's production-tuning note): quantized model weights loading faster at
  cold-start time is a second, independent motivation for that evaluation beyond
  inference-time throughput — worth a one-line addition to that debt item rather than a
  new one.
- **Gives backlog #4 (Kubernetes replica-count/HPA co-tuning) concrete knob names** to
  reference once that study is scoped: min/max replicas, autoscaling window, scale-down
  delay, and concurrency target are the five parameters an actual Kubernetes-pack
  autoscaling parameter set would need to expose — useful as a checklist when that study
  is eventually designed, not a new pack-request (the existing debt item already covers
  the general gap).
- **Confirms this repo's PVC-based model-loading pattern is on the fast side of the
  cold-start bandwidth spectrum**, consistent with the earlier Ch2/model-data-storage
  note's conclusion — no new action, just cross-referenced confirmation.
- **GPU failure-rate baseline is informational only** for this repo's current scale
  (single GPU, short-duration experiments) — noted for future reference if a study ever
  runs at a scale where hardware-failure noise could plausibly explain an anomalous
  experiment.

## Which Akamas parameters to explore

N/A — every finding here is Kubernetes/platform-level autoscaling, cold-start, or cost/
observability configuration, not a vLLM or GPU component parameter. No new
`ROADMAP.md` hypothesis; the one candidate addition (quantization also speeding
cold-start loading, extending the existing Run:ai Model Streamer item) is small enough
to fold into that existing debt item rather than needing separate confirmation — flagged
for the user to approve alongside that item's next edit.
