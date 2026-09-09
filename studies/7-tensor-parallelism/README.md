# 6-Data-Parallelism

**Status:** TODO
**Dates:** Scaffolded 2026-09-07

## Objective

First study on **NVIDIA L4** in this repo — a 1x g6.12xlarge node (4x L4, 24GB each,
Ada Lovelace/SM89), serving `Qwen/Qwen2.5-7B-Instruct`. Isolates the effect of **one
parameter, `data_parallel_size`**, across its full range on this node (1 through 4) —
4 fixed-configuration trials (`baseline` + 3 `preset` steps), no optimize step, no
`parametersSelection`. Every other tuned parameter stays at whatever
`doNotRenderParameters` leaves it at (vLLM's own real default) in all 4 steps —
`goal`/`windowing`/AIPerf load pattern are otherwise identical to `2-larger-model-g7e`.

The name reflects the actual reason for choosing this hardware: L4 GPUs have **no
NVLink** — only PCIe interconnect — which makes tensor parallelism (frequent
per-layer all-reduce across GPUs) comparatively expensive here, while data
parallelism (independent replicas, no cross-GPU synchronization needed) fits this
hardware well. See "Study design" below for the exact 4 steps.

## Study design — 4 fixed configurations, `data_parallel_size` the only variable

| Step | `data_parallel_size` | Every other tuned parameter |
|---|---|---|
| `baseline` | 1 (unrendered — vLLM's own default) | unrendered — vLLM's own default |
| `preset_dp2` | 2 (explicit `values`) | unrendered — vLLM's own default |
| `preset_dp3` | 3 (explicit `values`) | unrendered — vLLM's own default |
| `preset_dp4` | 4 (explicit `values`) | unrendered — vLLM's own default |

`gpu_memory_utilization: 0.90` is pinned in every step (same reason as
`2-larger-model-g7e`'s baseline: the pack's own `defaultValue` is 0.92, not 0.90).
`k8s/01-deployment_template.yaml` already has
`--data-parallel-size=${vLLM.data_parallel_size}` unconditionally in its args list, so
no template change was needed — only the study manifest's `steps:` changed.

## Differences from `2-larger-model-g7e`

Everything not listed here is identical — same `goal`/`constraints`, `windowing`
(`stability`, width 6), the baseline step's `doNotRenderParameters` shape (all 25
non-tuned parameters unrendered, only `gpu_memory_utilization: 0.90` pinned),
model/image (`Qwen/Qwen2.5-7B-Instruct`, `vllm/vllm-openai:v0.22.0`), and AIPerf load
pattern (12-level concurrency ramp, 150→1024, 300s/level).

1. **Hardware** — `g6.12xlarge` (4x NVIDIA L4, 24GB each) instead of `g7e.4xlarge` (1x
   RTX PRO 6000 Blackwell, 96GB). New node group `llm-serving-l4`, **not yet created**
   on the live cluster as of scaffolding — see `infra/README.md`.
2. **No `optimize` step, no `parametersSelection`, no `parameterConstraints`** —
   `2-larger-model-g7e` tunes 14 parameters via an optimizer; this study instead runs
   4 fixed configurations (`baseline` + 3 `preset` steps) that vary **only**
   `data_parallel_size` (1/2/3/4) and hold every other parameter at vLLM's own
   default — see "Study design" above. Nothing to search, no domain to violate, so
   `parametersSelection`/`parameterConstraints` are both omitted entirely (same
   reasoning `4-goodput-extended` used for its own baseline+preset design).
3. **Pod requests all 4 GPUs** (`nvidia.com/gpu: "4"`) in every step, including
   `baseline` (`data_parallel_size=1`, only 1 GPU actually used) — see
   `k8s/01-deployment_template.yaml`'s own comment: the Kubernetes device plugin only
   exposes as many GPUs to the container as the resource request asks for, so
   reserving fewer than 4 would make `preset_dp2`/`_dp3`/`_dp4` impossible without
   redeploying with different resources each time. Since this is a single dedicated,
   tainted GPU node, reserving all 4 upfront costs nothing (see prior discussion in
   chat — DCGM still reports per-GPU metrics for the idle GPUs independently of the
   pod's own resource request).
4. **Full 5-pack-changes metric/component catalog carried over** — all 98 telemetry
   metrics and all 6 components (`vllm`, `gpu` — since split into `gpu0`–`gpu3`, see
   "GPU metrics split per GPU instance" below —, `container`/`container_loadtest`,
   `cluster`/`cluster_loadtest`) ported unchanged, except `cluster.yaml`'s
   `node_role: llm-serving-l4` (was `llm-serving`) so the cluster-level PSI join
   scopes to the right node. This means this study collects the full DCGM/PSI/
   container metric set from day one, not just the goal's own throughput metrics —
   in particular per-GPU DCGM metrics across all 4 GPUs are directly useful here to
   see how load actually distributes as `data_parallel_size` increases.
5. **DCGM Exporter needs a NEW release** (`dcgm-exporter-l4`) — a single shared
   release's `nodeSelector` can only target one node-role at a time (same limitation
   `2-larger-model-g7e`'s `dcgm-exporter-g7e` hit) — see
   `k8s/monitoring/dcgm-exporter-values.yaml`.
6. **Akamas resource names** — renamed to keep every system/telemetry-instance/
   workflow/study name unique instance-wide: study `6-Data-Parallelism`, system
   `vLLM_Benchmark_6_Data_Parallelism`, telemetry instance
   `Prometheus_6_Data_Parallelism`, workflow `6-Data-Parallelism-Workflow`.

## "system" node group replacement — DONE (2026-09-07)

Per explicit request, `infra/eks/cluster.yaml` added a candidate replacement for the
shared `system` node group (`m6i.xlarge` → `m8a.xlarge`, expected more performant) as
a new node group, `system-m8a`. Both this and `llm-serving-l4` were created the same
day (`eksctl create nodegroup`, profile `lab`), and — since a managed node group's
instance type is immutable, so this couldn't be an in-place edit — the shared
workloads were then migrated onto `system-m8a` live: `cert-manager`,
`kube-prometheus-stack` (prometheus/alertmanager/grafana/kube-state-metrics/operator),
`nginx-ingress`, `external-dns`, `open-webui`. See `infra/README.md` for the full
account, including two gotchas hit and fixed during the migration (an AZ mismatch on
`system-m8a`'s own ASG, and an RWO-volume RollingUpdate deadlock on Grafana/
open-webui). This study's own AIPerf Job (`k8s/05-job.yaml`) and the
`cluster_loadtest` component (`akamas/components/cluster_loadtest.yaml`) were updated
to target `node-role: system-m8a` accordingly. The old `system` node group is now
empty (DaemonSets only) and can be scaled to 0 whenever you're satisfied nothing
regressed — not automated by anything in this repo, a deliberate manual step.

## Not done yet (deliberate follow-up steps, not part of this scaffold)

- **Scaling `llm-serving-l4` up and verifying the GPU** — the node group exists
  (created 2026-09-07) but `desiredCapacity: 0`; scale it up and confirm
  `nvidia.com/gpu: 4` shows up as allocatable before trusting anything downstream.
  eksctl already auto-selected the NVIDIA AMI correctly for `g6` (confirmed at
  nodegroup-creation time — no `ami:` pin needed, unlike `g7e`), so this should be a
  formality, but hasn't been checked against an actual running node yet.
- **Testing `tensor_parallel_size>1`** (for comparison against the
  `data_parallel_size` results this study produces) — deliberately out of scope here;
  this study isolates `data_parallel_size` only, per explicit request. A follow-up
  study (or additional preset steps) would be needed to test tensor parallelism on
  this same hardware.
- **Scaling `system` to 0** — the migration to `system-m8a` is done (see above); the
  old node group is idle but not yet scaled down.
- **Recalibrating the concurrency ramp for L4** — `k8s/05-job.yaml`'s 150→1024 sweep
  was calibrated on A10G (`1-goodput-realistic-load`'s README); this GPU's actual
  saturation point may differ.

## Prerequisites before this study can be started

- Scale `llm-serving-l4` up (`desiredCapacity`/`minSize` — can be done directly from
  the AWS Console since it's already `ACTIVE`) — verify `nvidia.com/gpu: 4` shows up
  as allocatable before trusting anything downstream.
- Install `dcgm-exporter-l4` (see `k8s/monitoring/dcgm-exporter-values.yaml`).
- **(2026-09-08) kv-cache-exporter sidecar — DONE**: `k8s/04-kv-cache-exporter-configmap.yaml`
  applied (ConfigMap `kv-cache-exporter`, namespace `llm-serving`), `k8s/02-service.yaml`
  re-applied (Service `vllm` now exposes `http:8000` + `kv-exporter:9400`) and
  `k8s/monitoring/servicemonitor.yaml` re-applied (ServiceMonitor `vllm` now has both
  endpoints). Without the ConfigMap the vLLM pod would stay in `ContainerCreating` until
  `apply_config.sh`'s rollout timeout. The sidecar itself only lands in the pod once the
  workflow re-applies the rendered Deployment. See "Absolute KV-cache metrics" below.
- **(2026-09-08) vLLM pack 1.7.0 — DONE**: built + installed on `akamas.lab.akamas.io`
  from the `toolbox` pod (source copied to `/work/vllm-170`), and the telemetry instance
  `Prometheus_7_Tensor_Parallelism` created — see `akamas/README.md` "Setup & run",
  step 0. The instance was the *only* resource `akamas create -f .../akamas` had failed
  to create against pack 1.6.1, which is why the first `Start` returned "No valid
  telemetry instance found for this study".
- Confirm the `vllm-model-cache` PVC lands in the same AZ as wherever `llm-serving-l4`
  schedules — the recurring AZ-mismatch pattern this repo has hit repeatedly.
- Supply `akamas/id_rsa` (excluded from this scaffold, same convention as every other
  study — **do not** copy an existing key from another study folder; see this
  session's own memory note on why a stray committed key keeps recurring).
- Smoke-test vLLM manually before creating the Akamas study — this is the first time
  this image/model runs on L4, unlike every other study's hardware which had prior art
  in this repo to lean on.
- Confirm all three optimization packs are actually installed at the versions this
  study assumes: vLLM **1.7.0** (was 1.6.1 until 2026-09-08), GPU 1.1.0, Kubernetes
  1.8.0-dev — `akamas list optimization-pack`.
- Validate every `akamas/*.yaml` file against a live Akamas instance
  (`akamas create -f ...`) before declaring this study ready — not yet done for this
  scaffold.

## GPU metrics split per GPU instance — DONE (2026-09-08)

The goal is to see every DCGM metric **per single GPU** in Akamas, not one series
aggregated across the four L4s. The single `gpu` component (`prometheus.gpu: .*`)
received all four GPUs' series for each metric and showed them collapsed into one
value. It is replaced by **one component per GPU** — `akamas/components/gpu0.yaml` to
`gpu3.yaml`, each with `prometheus.gpu: "0"`..`"3"` (the DCGM `gpu` label, the device
index) — and the 38 per-GPU DCGM queries in `akamas/telemetry/prometheus.yaml` lost
their `by(gpu)` grouping, so each returns exactly one series for its component's GPU.
Metric names and count are unchanged. Not yet verified live (Akamas endpoint
unreachable 2026-09-08); before the first trial confirm DCGM's `gpu` label values on
this node are literally `0`–`3` with `count by(gpu)(DCGM_FI_DEV_GPU_UTIL)` against
Prometheus. Study/workflow files were renamed to the `7-` prefix the same day.

## Absolute KV-cache metrics — DONE (2026-09-08, not yet verified live)

The KV-cache metrics we had (`kv_cache_usage_avg`/`_max`, `fleet_kv_cache_usage_avg`)
are all ratios of `vllm:kv_cache_usage_perc`, which can't be compared across this
study's 4 steps because each `tensor_parallel_size` gives the KV cache a different
capacity. vLLM `v0.22.0` has no numeric absolute KV gauge: the capacity exists only as
**string labels** on `vllm:cache_config_info` (`num_gpu_blocks`, `block_size`), and
PromQL cannot convert a label to a number — so a query alone can't do it. Added
instead:

- **vLLM pack 1.7.0** (`feature/kv-cache-absolute-metrics`, local clone, uncommitted):
  `kv_cache_capacity_tokens`, `kv_cache_used_tokens`, `kv_cache_capacity_gb`,
  `kv_cache_used_gb` on the `vLLM` component type.
- **`kv-cache-exporter` sidecar** in the vLLM pod (`k8s/04-kv-cache-exporter-configmap.yaml`
  holds the stdlib-Python script; container, port 9400 and ConfigMap volume in
  `k8s/01-deployment_template.yaml`; port in `k8s/02-service.yaml`; scrape endpoint in
  `k8s/monitoring/servicemonitor.yaml`). It reads vLLM's own `/metrics` on localhost and
  republishes `vllm_kv_cache_capacity_tokens`, `vllm_kv_cache_used_tokens`,
  `vllm_kv_cache_capacity_bytes`, `vllm_kv_cache_used_bytes` (+ blocks, block size,
  usage ratio, `scrape_success`). Token values are vLLM's own numbers; the byte values
  use 57344 B/token (2 x 28 layers x 4 KV heads x 128 head_dim x 2 bytes, Qwen2.5-7B-
  Instruct bf16 — env vars on the sidecar, update for any other model or an fp8 KV cache).
- **4 telemetry entries** in `akamas/telemetry/prometheus.yaml` (98 → 102 metrics) —
  see `akamas/README.md` "Telemetry" for the exact queries.
- **Pod template annotation** `kubectl.kubernetes.io/default-container: vllm` — with two
  containers, `kubectl logs deployment/vllm` in `apply_config.sh` would otherwise error;
  both `kubectl logs` lines there now also pass `--all-containers` so the sidecar's own
  log lands in the trial output.
- **Fixed on the way** (stale copies from `6-data-parallelism`, would have applied the
  wrong study's manifests on every trial): `k8s/apply_config.sh` line 1 (`DEPLOY_FILE`)
  and `k8s/run_test_goodput.sh` line 3 (`BENCH_FILE`) now point at
  `studies/7-tensor-parallelism/k8s/`.

Verified locally only: exporter parsing/arithmetic against a fixture of vLLM's
`/metrics` text and its unreachable → not-ready → ready → gone state transitions. Not
verified: the real scrape on the cluster, `akamas build`/`install` of pack 1.7.0, and
`akamas create` of the telemetry instance (Akamas endpoint unreachable 2026-09-08).

## How to run

```bash
# vLLM pack 1.7.0 first (absolute KV-cache metrics). Run from this repo's root; the pack
# clone is the sibling folder ../optimization-packs/vllm (writes vLLM_1-7-0.json to cwd)
akamas build optimization-pack ../optimization-packs/vllm
akamas install -f optimization-pack <JSON written by the build command>
# kv-cache-exporter sidecar one-time applies
kubectl apply -f studies/7-tensor-parallelism/k8s/04-kv-cache-exporter-configmap.yaml
kubectl apply -f studies/7-tensor-parallelism/k8s/02-service.yaml
kubectl apply -f studies/7-tensor-parallelism/k8s/monitoring/servicemonitor.yaml
# Akamas resources
akamas create -f studies/7-tensor-parallelism/akamas/
akamas start study "7-Tensor-Parallelism"
```

If the system was already created before the 2026-09-08 per-GPU change (no update verb
exists for components or telemetry instances):

```bash
akamas delete component "gpu" "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create component "studies/7-tensor-parallelism/akamas/components/gpu0.yaml" "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create component "studies/7-tensor-parallelism/akamas/components/gpu1.yaml" "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create component "studies/7-tensor-parallelism/akamas/components/gpu2.yaml" "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create component "studies/7-tensor-parallelism/akamas/components/gpu3.yaml" "vLLM_Benchmark_7_Tensor_Parallelism"
akamas delete telemetry-instance "Prometheus_7_Tensor_Parallelism" "vLLM_Benchmark_7_Tensor_Parallelism"
akamas create telemetry-instance studies/7-tensor-parallelism/akamas/telemetry/prometheus.yaml "vLLM_Benchmark_7_Tensor_Parallelism"
```

## Results

<Filled in by the study-recap skill once the study finishes.>

## Conclusions

<Filled in by the study-recap skill once the study finishes.>
