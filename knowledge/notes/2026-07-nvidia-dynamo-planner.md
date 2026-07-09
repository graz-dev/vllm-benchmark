<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# NVIDIA Dynamo Planner (LLM-aware autoscaler)

**Source:** [NVIDIA Dynamo docs — Planner component](https://docs.nvidia.com/dynamo/components/planner)
**Date distilled:** 2026-07-08

## Problem addressed

Argues traditional Kubernetes autoscalers (HPA, KEDA) fail for LLM inference because
request cost is wildly non-uniform (a 32k-token prompt costs orders of magnitude more
than a short one), prefill and decode scale along different axes (compute-bound vs.
memory/KV-cache-bound — "a single replica count doesn't capture both"), the metrics that
matter (TTFT, ITL) don't map to CPU/memory utilization, and GPU worker startup takes
minutes, making both over- and under-provisioning expensive. The Planner is Dynamo's
purpose-built autoscaler that scales prefill and decode worker pools **independently**,
targeting TTFT/ITL SLAs directly rather than a generic utilization metric — and it
**explicitly supports vLLM** as a backend, making it more directly relevant to this
repo's stack than the other Dynamo/topology tools already noted.

## Levers / parameters touched

- **`optimization_target`**: `throughput` (default — maximize throughput via queue-depth
  and KV-cache-utilization thresholds), `latency` (aggressive scale-up to keep queues
  minimal), or `sla` (directly targets `ttft_ms`/`itl_ms` via engine performance
  modeling; needs SLA values and optionally pre-deployment profiling).
- **Two scaling loops that can run together**: throughput-based (slow cadence, default
  180s, sets a capacity *floor* using engine performance modeling + traffic prediction)
  and load-based (fast cadence, default 5s, reacts to real-time bursts using live
  per-iteration engine metrics — no pre-deployment profiling needed).
- **`ttft_ms` (default 500), `itl_ms` (default 50)** — the actual SLA targets driving
  `sla`-mode scaling.
- **`max_gpu_budget` (default 8)** — hard GPU ceiling across all workers; **`min_endpoint`
  (default 1)** — floor per worker type, also the documented workaround for the
  scale-down-drops-in-flight-requests limitation (raise this to avoid killing workers
  mid-request).
- **`load_scaling_down_sensitivity` (default 80, range 0–100)** — how aggressively to
  scale down; **`load_predictor`** — traffic forecasting model choice (ARIMA default,
  also Prophet/Kalman/Constant).
- **Independent prefill vs. decode worker scaling**: prefill scales on input-queue depth
  and compute pressure; decode scales on KV-cache utilization and memory pressure — two
  separate replica counts, not one.
- **vLLM integration requirement**: load-based scaling on vLLM needs
  `InstrumentedScheduler` and the `DYN_FORWARDPASS_METRIC_PORT` env var — i.e. vLLM must
  be launched with Dynamo-specific instrumentation for the fast-loop signals to exist;
  throughput-based scaling works without this.

## Key results

- This is a component/config-reference doc, not a benchmark paper — no throughput/
  latency benchmark numbers are given. The "key results" are the concrete default
  values and architecture, useful as a reference schema rather than a performance claim:
  defaults `ttft_ms=500`, `itl_ms=50`, `max_gpu_budget=8`, `min_endpoint=1`,
  `throughput_adjustment_interval_seconds=180`, `load_adjustment_interval_seconds=5`.
- Backend support matrix as documented: vLLM supports **both** throughput-based and
  load-based scaling (load-based requires the instrumentation above); TensorRT-LLM
  supports both (load-based only for non-attention-DP workers); SGLang supports
  throughput-based only as of Dynamo 1.2.0 (load-based gated on a missing FPM module).
- Explicit known limitation: scale-down **terminates workers without draining** —
  in-flight requests (including mid-prefill ones) fail when a worker is killed to scale
  down. This is a hard operational caveat, not a tunable-away edge case; the only
  mitigations documented are raising `min_endpoint` or lowering
  `load_scaling_down_sensitivity` to scale down less aggressively.
- Router coupling: KV Router works with both scaling modes; round-robin/random routers
  only work with throughput-based scaling — load-based scaling requires a KV-aware
  router and doesn't account for requests still queued in the router before engine
  assignment.

## Implications for vLLM/k8s tuning

- This is the most directly relevant "smarter autoscaler" source found so far for **H4 /
  backlog #4** (co-tuning Kubernetes replica count / HPA alongside vLLM parameters,
  logged in `ROADMAP.md`): the Planner is essentially a purpose-built, SLA-aware
  replacement for a generic HPA specifically for the replica-count axis this repo has
  repeatedly flagged as unmodeled. Unlike Akamas (offline, experiment-driven
  optimization of a fixed set of parameters), the Planner is an **online, always-running
  autoscaler** — a different tool category solving an adjacent but distinct problem
  (continuous runtime scaling vs. finding a best static config). They're complementary,
  not substitutes: a study could use Akamas to find the best per-instance vLLM config,
  then (separately, outside Akamas) use something like the Planner to decide how many
  replicas of that config to run at a given moment.
- The "prefill and decode need independent replica counts, not one" point reinforces
  the disaggregation-topology theme from the distributed-inference series
  (`knowledge/notes/2026-07-distributed-inference-scaling-dimensions.md` and its two
  follow-ups) — another independent source saying a single aggregated replica-count
  parameter can't represent a disaggregated deployment correctly.
- The scale-down-without-draining limitation is a concrete operational risk to note if
  this repo ever combines Akamas-driven config changes with **any** autoscaler
  (Planner or otherwise) on the same running deployment — an autoscaler scaling down
  mid-experiment could corrupt a load test's results by dropping in-flight requests
  independent of the vLLM parameter under test. Relevant to how any future replica-count
  study (backlog #4) should be run: freeze/disable autoscaling during a controlled
  Akamas experiment, or account for it explicitly in the study's methodology.
- Conditions to flag: default SLA targets (`ttft_ms=500`, `itl_ms=50`) are Dynamo
  defaults, not evidence of a "good" SLA for any specific model/hardware — don't reuse
  them as this repo's own SLO targets without deriving them from the actual study's
  requirements.

## Which Akamas parameters to explore

- No new vLLM/GPU per-instance parameters — the Planner operates entirely at the
  Kubernetes replica-count/autoscaling layer, which is the same gap already logged
  against H4/backlog #4 in `ROADMAP.md` (a Kubernetes-pack replica-count/HPA parameter
  not currently modeled). This note doesn't add a new pack-request item, it strengthens
  the existing one with a concrete example of what "smart" replica scaling for LLM
  inference looks like in practice.
- If this repo ever adopts Dynamo's Planner for actual autoscaling (separate from any
  Akamas study), the vLLM instrumentation it requires (`InstrumentedScheduler`,
  `DYN_FORWARDPASS_METRIC_PORT`) would be a deployment-manifest concern for that study's
  `k8s/` folder, not an Akamas `parametersSelection` entry — flagging here so it isn't
  mistaken for a pack-modeled parameter later.
