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
   metrics and all 6 components (`vllm`, `gpu`, `container`/`container_loadtest`,
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
- Confirm the `vllm-model-cache` PVC lands in the same AZ as wherever `llm-serving-l4`
  schedules — the recurring AZ-mismatch pattern this repo has hit repeatedly.
- Supply `akamas/id_rsa` (excluded from this scaffold, same convention as every other
  study — **do not** copy an existing key from another study folder; see this
  session's own memory note on why a stray committed key keeps recurring).
- Smoke-test vLLM manually before creating the Akamas study — this is the first time
  this image/model runs on L4, unlike every other study's hardware which had prior art
  in this repo to lean on.
- Confirm all three optimization packs are actually installed at the versions this
  study assumes: vLLM 1.6.1, GPU 1.1.0, Kubernetes 1.8.0-dev — `akamas list
  optimization-pack`.
- Validate every `akamas/*.yaml` file against a live Akamas instance
  (`akamas create -f ...`) before declaring this study ready — not yet done for this
  scaffold.

## How to run

```bash
akamas create -f studies/6-data-parallelism/akamas/
akamas start study "6-Data-Parallelism"
```

## Results

<Filled in by the study-recap skill once the study finishes.>

## Conclusions

<Filled in by the study-recap skill once the study finishes.>
