# 5-Pack-Changes — Akamas resources

**Created:** 2026-09-07 (scaffolded from `3-comparison-a10`)

A **pack-verification study**, not a tuning study. Maximizes **goodput** —
`vLLM.prefill_token_throughput + vLLM.decode_token_throughput` — for
`Qwen/Qwen2.5-7B-Instruct`, served by vLLM on the existing single NVIDIA A10G GPU
(`g5.2xlarge`, node group `llm-serving`), across ~10 experiments, with no goal
constraints. Its sole purpose is to confirm the new GPU/DCGM and Kubernetes/PSI
optimization-pack metrics collect correctly end-to-end. See the study's own top-level
`README.md`, "Differences from `3-comparison-a10`", for everything actually different
from that study (goal constraints removed, `trim` windowing, flat single-concurrency
load, ~10 experiments, 2 new component pairs — `cluster`/`cluster_loadtest` and
`container`/`container_loadtest` — 53 new telemetry metrics).

## Versions

- **vLLM optimization pack**: **1.6.0** (same as `3-comparison-a10`) — **TODO,
  re-verify**: `akamas describe optimization-pack vLLM`.
- **GPU optimization pack**: **1.1.0** (`feature/dcgm-counters-coverage`, not yet
  merged as of scaffolding) — this is the pack change being verified. **TODO,
  re-verify it's actually installed**: `akamas describe optimization-pack GPU`.
- **Kubernetes optimization pack**: **1.8.0-dev** (`feature/psi-cluster-metrics`, not
  yet merged as of scaffolding) — the other pack change being verified. **TODO,
  re-verify**: `akamas describe optimization-pack "Kubernetes"`.
- **Target workload**: `Qwen/Qwen2.5-7B-Instruct`, image tag `vllm/vllm-openai:v0.22.0`
  — identical to `3-comparison-a10`, already proven on this exact A10G node group.
- **Telemetry provider**: Prometheus (via `kube-prometheus-stack`).

## System

- `container` → `Kubernetes Container` — **now has `prometheus.pod: ^vllm-.*`**
  (scoped to vLLM's own pod specifically, not `.*`; had zero metrics wired and no
  properties in `3-comparison-a10`).
- `container_loadtest` → `Kubernetes Container` — **new**, `prometheus.pod:
  ^aiperf-benchmark-.*`. Same component type/metric catalog as `container`, scoped to
  the AIPerf load-test's own pod instead, so this study can see the load generator's
  own container-level resource usage too, not just vLLM's.
- `gpu` → `GPU` (metrics-only, `prometheus.{pod,gpu}: .*`, unchanged).
- `vLLM` → `vLLM` (the pack under study, `prometheus.{pod,model}: .*`, unchanged).
- `cluster` → `Kubernetes Cluster` — **new**, `prometheus.node_role: llm-serving`. First
  use of this component type in this repo; needed for the 5 cluster-level PSI metrics,
  which carry no pod/GPU label.
- `cluster_loadtest` → `Kubernetes Cluster` — **new**, `prometheus.node_role: system`.
  Same component type/metric catalog as `cluster`, scoped to the "system" node group
  (where `k8s/05-job.yaml`'s AIPerf Job actually schedules, via its own `nodeSelector`)
  instead of the GPU node — so this study can see load-test-side node pressure too.

## Telemetry

Same metric catalog as `3-comparison-a10` (TTFT/ITL/throughput, saturation signals,
KV-cache health, sequence-length distribution, per-pod fleet metrics, existing GPU/DCGM
metrics, MFU compute/memory-bandwidth metrics), plus **53 new metrics** — 23 GPU/DCGM,
25 Kubernetes Container (6 PSI + the other 19 in that pack's Container catalog), 5
Kubernetes Cluster (PSI) — see the study README's "New metrics" section for the full
list and how each is scoped, including:
- the 2-hop PromQL join (`node_pressure_*` → `node_uname_info` → `kube_node_labels`)
  the 5 cluster-level PSI metrics need, and the live `kube-state-metrics` allowlist
  change that join required;
- the `container!=""` filter every cAdvisor-sourced container query needs (this
  cluster's cAdvisor emits a pod-level aggregate and a pause-container series per pod
  in addition to the real container's — verified live, both lack a `container` label
  so this filter cleanly excludes them);
- **each of these 25 Container metrics and 5 Cluster metrics is evaluated twice** —
  once via `container`/`cluster` (vLLM's pod / the GPU node) and once via
  `container_loadtest`/`cluster_loadtest` (the AIPerf pod / the load-test's node) — same
  query template, different component-instance property substitution (see "System"
  above).

## Workflow: `5-Pack-Changes-Workflow`

Same three-task shape as `3-comparison-a10`: `Write config` (FileConfigurator),
`Apply config` (Executor, `apply_config.sh`, unchanged 75m timeout), `RunTest` (Executor,
`run_test_goodput.sh`). **`RunTest`'s timeout lowered to 45m** (from 105m) — the load
test itself dropped from a 12-level ~60min sweep to a single flat 5min level (see study
README), so `run_test_goodput.sh`'s own `kubectl wait` timeout is now 30m (from 95m) and
this task keeps the same 15min margin above it.

## Study: `5-Pack-Changes`

- **Goal**: maximize `vLLM.prefill_token_throughput + vLLM.decode_token_throughput`.
  **No `constraints`** (removed from `3-comparison-a10`'s TTFT/ITL SLA thresholds) —
  this study isn't testing SLA compliance.
- **Windowing**: `trim`, `["1m", "1m"]` on the `RunTest` task (replaces
  `3-comparison-a10`'s `stability` windowing, which existed to find a stable point
  within a concurrency ramp this study no longer runs).
- **`parametersSelection`**: same 14 parameters as `3-comparison-a10`, domains/
  categories unchanged.
- **`parameterConstraints`**: same 7 as `3-comparison-a10`, unchanged — see that
  study's README for the full rationale per constraint.
- **Baseline step**: identical to `3-comparison-a10`'s (`doNotRenderParameters` for all
  25 non-pinned parameters, only `gpu_memory_utilization: 0.90` explicitly set).
- **Optimize step**: `numberOfExperiments: 10` (down from 1000),
  `maxFailedExperiments: 5` (down from 200) — enough configs to exercise the new
  metrics under varied conditions, not an actual optimization budget.

## Validation performed

Structurally consistent with `3-comparison-a10` (parameter/metric names, domains,
component references, `system:` fields) since this is a clone with targeted edits, not
a from-scratch build. The 34 new telemetry entries were checked against the actual pack
source (GPU pack `feature/dcgm-counters-coverage`, Kubernetes pack
`feature/psi-cluster-metrics`) for exact metric names, and the cluster-level PSI join
query was verified live against this cluster's own Prometheus (`kube_node_labels`,
`node_uname_info`, `node_pressure_*`, `container_pressure_*` all confirmed present with
the expected labels) before being written here. **Not yet validated against a live
`akamas create -f`** — run the commands below against a real instance, and re-confirm
all three pack versions first (see "Versions" above).

## Placeholders left — fill in before running

- **`akamas/id_rsa`** — deliberately excluded from this scaffold (same convention as
  every other study in this repo). Supply your own `toolbox` host SSH key at this path.
- **vLLM image tag**: `k8s/01-deployment_template.yaml` pins `vllm/vllm-openai:v0.22.0`
  — unchanged from `3-comparison-a10`.
- **Concurrency**: `k8s/05-job.yaml`'s `CONCURRENCY_LIST="428"` — a single middle value
  from `3-comparison-a10`'s own 12-level sweep, not independently recalibrated.

## Setup & run

```bash
# Confirm all three installed pack versions first (see "Versions" above)
akamas describe optimization-pack vLLM
akamas describe optimization-pack GPU
akamas describe optimization-pack "Kubernetes"

# Typed, per-resource form (dependency order matters)
akamas create system             studies/5-pack-changes/akamas/system.yaml
akamas create component          studies/5-pack-changes/akamas/components/container.yaml          "vLLM_Benchmark_5_Pack_Changes"
akamas create component          studies/5-pack-changes/akamas/components/container_loadtest.yaml "vLLM_Benchmark_5_Pack_Changes"
akamas create component          studies/5-pack-changes/akamas/components/gpu.yaml                "vLLM_Benchmark_5_Pack_Changes"
akamas create component          studies/5-pack-changes/akamas/components/vllm.yaml               "vLLM_Benchmark_5_Pack_Changes"
akamas create component          studies/5-pack-changes/akamas/components/cluster.yaml            "vLLM_Benchmark_5_Pack_Changes"
akamas create component          studies/5-pack-changes/akamas/components/cluster_loadtest.yaml    "vLLM_Benchmark_5_Pack_Changes"
akamas create telemetry-instance studies/5-pack-changes/akamas/telemetry/prometheus.yaml "vLLM_Benchmark_5_Pack_Changes"
akamas create workflow           studies/5-pack-changes/akamas/5-Pack-Changes-Workflow.yaml
akamas create study              studies/5-pack-changes/akamas/5-Pack-Changes.yaml

akamas start study "5-Pack-Changes"
```

Or, bulk form (same dependency order still applies internally — every file
self-describes its `kind:`/`system:`):

```bash
akamas create -f studies/5-pack-changes/akamas/
akamas start study "5-Pack-Changes"
```
