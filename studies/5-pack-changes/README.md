# 5-Pack-Changes

**Status:** TODO
**Dates:** Scaffolded 2026-09-07

## Objective

Not a tuning study — a **pack-verification study**. Its only purpose is to confirm
that the recently-added optimization-pack metrics actually collect end-to-end on a
real running study, before those packs are trusted in any future study:

- **GPU pack** (`Documents/gitlab/nvidia-gpu`, `feature/dcgm-counters-coverage`,
  1.0.1 → 1.1.0): 23 new DCGM-derived metrics.
- **Kubernetes pack** (`Documents/gitlab/kubernetes`, `feature/psi-cluster-metrics`,
  1.8.0-dev): 11 new PSI (Pressure Stall Information) metrics, 6 container-level +
  5 cluster-level.

Cloned from `3-comparison-a10` (same model — `Qwen/Qwen2.5-7B-Instruct` — same A10G
hardware, same `parametersSelection`/`parameterConstraints`) since that study's system
already had every component this one needs, minus the new metrics. See that study's
README for the full per-parameter rationale and incident history; this README only
documents what's actually different here.

## Differences from `3-comparison-a10`

Everything not listed here is identical — same `parametersSelection`,
`parameterConstraints`, `baseline`/`optimize` step structure, node targeting
(`node-role: llm-serving`, A10G/`g5.2xlarge`), container resources, and DCGM Exporter
setup (reuses the existing `dcgm-exporter` release, no new Helm install needed — its
`dcgm_counters.csv` already had every DCGM field the new GPU pack metrics need enabled).

1. **Goal constraints removed** — no `goal.constraints` (the TTFT/ITL SLA thresholds).
   This study isn't testing SLA compliance, only metric collection, so there was no
   reason to risk an experiment being marked as a constraint violation for a reason
   unrelated to what's actually being verified.
2. **Windowing: `trim` instead of `stability`** — `{type: trim, trim: ["1m", "1m"],
   task: RunTest}`, discarding the first/last minute of each trial's single flat load
   and windowing over the rest. `3-comparison-a10`'s `stability` windowing existed to
   find a stable point within a 12-level concurrency ramp; this study doesn't ramp.
3. **Single flat concurrency level, not a 12-level sweep** — `k8s/05-job.yaml`'s
   `CONCURRENCY_LIST` is `"428"` (was `"150,179,213,253,302,359,428,509,606,722,860,
   1024"`), a constant 5-minute (300s) load at a middle concurrency value (the 7th of
   `3-comparison-a10`'s own 12 levels — neither the lowest nor the highest). Shrinks
   each trial's load-test phase from ~60 minutes to 5, which is all ~10 experiments
   need to exercise the new metrics. `k8s/run_test_goodput.sh`'s `kubectl wait` timeout
   and the workflow's `RunTest` task timeout were both lowered to match (30m / 45m,
   down from 95m / 105m).
4. **`optimize` step: ~10 experiments, not 1000** — `numberOfExperiments: 10`,
   `maxFailedExperiments: 5`. This study isn't optimizing anything; a handful of
   different vLLM configs is enough to confirm the new metrics collect consistently
   across varied conditions.
5. **2 new component pairs** — needed because the new metrics don't attach to the
   existing `gpu`/`vllm`/`container` components the way every other metric here does:
   - `cluster` / `cluster_loadtest` (`akamas/components/cluster*.yaml`, `componentType:
     Kubernetes Cluster`) — first use of this component type in this repo. The 5
     cluster-level PSI metrics (node-exporter's `node_pressure_*`) carry no pod/GPU
     label, only a node identity. `cluster` scopes to the GPU node (`node_role:
     llm-serving`); `cluster_loadtest` scopes to the node running the AIPerf load test
     itself (`node_role: system`, matching `k8s/05-job.yaml`'s own `nodeSelector`) —
     same metric templates, evaluated once per component instance.
   - `container` / `container_loadtest` — `container` gained
     `properties.prometheus.pod: ^vllm-.*` (it had zero metrics wired in
     `3-comparison-a10` and, critically, was **not** scoped to `.*` the way
     `gpu`/`vllm` are, since generic Kubernetes container metrics exist for every pod
     in the cluster, not just vLLM's — an unscoped `.*` would have silently aggregated
     every pod's CPU/memory together). `container_loadtest` is a new second instance
     of the same component type, scoped to `^aiperf-benchmark-.*` — the load test's
     own pod — so this study can see the load generator's own container-level resource
     usage too, not just vLLM's.
6. **53 new telemetry metrics** in `akamas/telemetry/prometheus.yaml` (each Container/
   Cluster metric evaluated twice, once per component pair above) — see "New metrics"
   below for the full list and how each is scoped.
7. **Akamas resource names** — renamed to keep every system/telemetry-instance/
   workflow/study name unique instance-wide: study `5-Pack-Changes`, system
   `vLLM_Benchmark_5_Pack_Changes`, telemetry instance `Prometheus_5_Pack_Changes`,
   workflow `5-Pack-Changes-Workflow`.

## New metrics

**23 GPU/DCGM metrics** (bound to the `gpu` component, scoped by `$POD$`/`$GPU$` same
as every existing GPU metric): `gpu_fp64_pipe_active`, `gpu_sm_clock`, `gpu_mem_clock`,
`gpu_total_energy_consumption`, `gpu_mem_copy_util`, `gpu_enc_util`, `gpu_dec_util`,
`gpu_gr_engine_active`, `gpu_xid_errors`, `gpu_uncorrectable_remapped_rows`,
`gpu_correctable_remapped_rows`, `gpu_row_remap_failure`, `gpu_clock_throttle_reasons`,
`gpu_fb_reserved`, `gpu_fb_used_percent`, `gpu_nvlink_bandwidth_total`,
`gpu_vgpu_license_status`, `gpu_pcie_tx_bytes`, `gpu_pcie_rx_bytes`, `gpu_count`,
`gpu_fan_speed`, `gpu_slowdown_temp`, `gpu_pstate`.

**25 Container metrics — the Kubernetes pack's full Container catalog**, not just PSI
(bound to `container` for vLLM's own pod and `container_loadtest` for the AIPerf pod;
same query template, different `$POD$` per component):
- 6 PSI (cAdvisor `container_pressure_*`): `container_cpu_pressure_some`,
  `container_cpu_pressure_full`, `container_memory_pressure_some`,
  `container_memory_pressure_full`, `container_io_pressure_some`,
  `container_io_pressure_full`.
- 19 more (cAdvisor + kube-state-metrics): `container_cpu_used`,
  `container_cpu_used_max`, `container_cpu_util`, `container_cpu_util_max`,
  `container_cpu_throttle_time`, `container_cpu_throttled_millicores`,
  `container_cpu_request`, `container_cpu_limit`, `container_memory_used`,
  `container_memory_used_max`, `container_memory_util`, `container_memory_util_max`,
  `container_memory_working_set`, `container_memory_resident_set`,
  `container_memory_cache`, `container_memory_request`, `container_memory_limit`,
  `container_restarts`, `container_oom_kills_count`.

Every cAdvisor-sourced query here needed a `container!=""` filter — **verified live,
not assumed**: this cluster's cAdvisor emits 3 series per pod per metric (a pod-level
aggregate, a pause/sandbox container, and the real workload container), and only the
real container's series carries a `container` label. Without the filter, `sum()`
silently double-counts (pod-level + real container both included) — caught and fixed
in this same scaffolding pass, since the first draft of the 6 PSI queries above missed
it too. Two metrics needed an approximation instead of a direct source metric,
confirmed live: this cluster's cAdvisor has no
`container_cpu_cfs_throttled_seconds_total` (0 series), only the periods-based
counters (`container_cpu_cfs_throttled_periods_total` /
`container_cpu_cfs_periods_total`) — `container_cpu_throttle_time` uses their ratio,
and `container_cpu_throttled_millicores` approximates seconds from periods using the
standard Linux CFS default period (100ms).

**10 Cluster-level PSI metrics** (5 metrics × 2 components — `cluster` for the GPU
node, `cluster_loadtest` for the load-test's node — from node-exporter's
`node_pressure_*`): `k8s_cluster_cpu_pressure`, `k8s_cluster_memory_pressure_some`,
`k8s_cluster_memory_pressure_full`, `k8s_cluster_io_pressure_some`,
`k8s_cluster_io_pressure_full`. These carry no pod/GPU label — only a node identity —
so scoping each to a specific node (the A10G GPU node for `cluster`, the "system" node
for `cluster_loadtest` — not whichever other node happens to also be up) needed a
two-hop PromQL join instead of a simple label match:

1. `node_pressure_*` is keyed by node-exporter's own `instance` (`<node-ip>:9100`).
2. `node_uname_info` (also node-exporter) joins `instance` → `nodename` (the
   Kubernetes Node object's name).
3. `kube_node_labels` (kube-state-metrics) joins `node` → the same name, and carries
   `label_node_role` — the label this study actually filters on (`$NODE_ROLE$`,
   from each component's own `properties.prometheus.node_role` — `llm-serving` for
   `cluster.yaml`, `system` for `cluster_loadtest.yaml`; same query template in
   `telemetry/prometheus.yaml`, evaluated once per component instance).

Step 3 required a **live infrastructure change** made 2026-09-07 as part of scaffolding
this study: `kube-state-metrics` (a subchart of the shared `kube-prometheus-stack` Helm
release) ships with `metricLabelsAllowlist: []` by default, so `kube_node_labels` was
carrying zero label pairs — verified empirically (`kube_node_labels` returned no
series) before making the change. Fixed via
`helm upgrade kube-prometheus-stack -n monitoring prometheus-community/kube-prometheus-stack --reuse-values -f <override>`
with `kube-state-metrics.metricLabelsAllowlist: ["nodes=[node-role]"]`. This is a small,
additive change to shared monitoring infra (adds one label to one metric; nothing
else in the release changed) — confirmed via a live Prometheus query that the full
2-hop join correctly isolates a single node's PSI series by role before writing these
queries. Not reverted; this label is now permanently available for any future study.

## Prerequisites before this study can be started

- Turn the A10G `llm-serving` node group back on if scaled down (`desiredCapacity`
  0→1) — see `infra/README.md`.
- Confirm the `vllm-model-cache` PVC lands in the same AZ as wherever the A10G node
  schedules (the recurring AZ-mismatch pattern documented across other studies in this
  repo — recreate the PVC if it's pinned to a different AZ).
- Supply `akamas/id_rsa` (excluded from this scaffold, same convention as
  `studies/_TEMPLATE`).
- Clear the shared AIPerf dataset cache (`/benchmarks/sharegpt-cache/inputs.json` on
  the `aiperf-results` PVC) if it currently has a different model's name baked in.
- Confirm all three optimization packs are actually installed at the versions this
  study assumes before creating its system: vLLM 1.6.0, GPU 1.1.0
  (`feature/dcgm-counters-coverage`, not yet merged as of scaffolding), Kubernetes
  1.8.0-dev (`feature/psi-cluster-metrics`, not yet merged as of scaffolding) — `akamas
  list optimization-pack`.
- Validate every `akamas/*.yaml` file against a live Akamas instance
  (`akamas create -f ...`) before declaring this study ready — not yet done for this
  scaffold.

## How to run

```bash
akamas create -f studies/5-pack-changes/akamas/
akamas start study "5-Pack-Changes"
```

## Results

<Filled in by the study-recap skill once the study finishes.>

## Conclusions

<Filled in by the study-recap skill once the study finishes.>
