<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Kubernetes GPU Scheduling: Beyond the Device Plugin (Operator, Sharing, DRA)

**Source:** [NVIDIA GPU Operator docs](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html),
[NVIDIA/k8s-device-plugin](https://github.com/NVIDIA/k8s-device-plugin),
[Kubernetes docs — Schedule GPUs](https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/),
[NVIDIA GPU Operator — Time-Slicing GPUs](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html),
[NVIDIA Technical Blog — Getting the Most Out of the A100 GPU with MIG](https://developer.nvidia.com/blog/getting-the-most-out-of-the-a100-gpu-with-multi-instance-gpu/),
[Kubernetes v1.34 — DRA graduated to GA](https://kubernetes.io/blog/2025/09/01/kubernetes-v1-34-dra-updates/),
[Kubernetes docs — Dynamic Resource Allocation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/),
[CNCF blog — Understanding Dynamic Resource Allocation in Kubernetes](https://www.cncf.io/blog/2026/07/01/understanding-dynamic-resource-allocation-in-kubernetes/)
**Date distilled:** 2026-07-13

## Problem addressed

This repo's own deployment template already uses the basic pattern for scheduling a pod
onto a GPU node (`nodeSelector` + a `nvidia.com/gpu: NoSchedule` toleration, one A10G per
node). This note covers what's *beyond* that basic pattern: how a cluster's GPU stack
gets installed/managed at scale (the GPU Operator), why whole-GPU-only allocation is the
device plugin's core limitation, the three mechanisms that address it (MIG, time-slicing,
MPS), and Dynamic Resource Allocation (DRA) — the newer Kubernetes API for expressing
resource requests the classic extended-resource model can't.

## Levers / parameters touched

Infrastructure/cluster-setup choices, not vLLM parameters: GPU Operator installation,
device-plugin GPU-sharing mode (none/time-slicing/MPS/MIG), DRA driver presence, and
node topology labeling (NVLink/NUMA-aware placement).

## Key results

- **NVIDIA GPU Operator** automates the whole per-node GPU stack via DaemonSets in
  dependency order: containerized driver install, NVIDIA Container Toolkit, the device
  plugin, DCGM Exporter (Prometheus metrics on port 9400), and the MIG Manager. Replaces
  manual per-node driver/plugin installs, which don't scale and drift across nodes.
- **NVIDIA device plugin** advertises GPUs as the extended resource `nvidia.com/gpu`.
  Kubernetes' extended-resource model requires `requests == limits` with **no fractional
  values** — this whole-GPU-only constraint is the documented reason sharing needed
  separate extensions (time-slicing/MPS config, MIG integration) rather than just finer
  resource units.
- **Three GPU-sharing mechanisms, different isolation levels**:
  - **MIG** (A100/H100/GH200 generations): hardware-level partitioning into up to 7
    isolated instances, each with dedicated memory/cache/compute — strongest isolation.
    **Key limitation confirmed**: MIG does not expose NVLink between instances, so
    tensor-parallel inference spanning MIG slices doesn't work — a full card is needed
    for TP≥2 on one host (this matches what this repo's `ROADMAP.md` had already flagged
    as an assumption, now source-confirmed). Not every slice-size combination is valid
    (bounded by 7 compute-slices and total card memory).
  - **Time-slicing**: software/temporal multiplexing, no memory or fault isolation
    between replicas, simplest to configure via the GPU Operator — weakest isolation.
  - **MPS**: CUDA-level concurrent kernel execution under one shared CUDA context
    (lower context-switch overhead than time-slicing's sequential model), partial
    isolation — no hardware memory isolation, so one misbehaving process can affect
    others. Sits between time-slicing and MIG on the isolation spectrum. MIG slices can
    themselves be time-sliced internally to oversubscribe beyond the 7 hardware
    partitions.
- **Dynamic Resource Allocation (DRA)**: core DRA graduated to **GA in Kubernetes
  v1.34** (Sept 2025). Solves what extended resources can't express — workloads
  describe device *properties* (not just a count), letting the scheduler match actual
  devices; supports prioritized device-list alternatives and (alpha in v1.34)
  "consumable capacity," where multiple independent pods share slices of one physical
  device. Vendor DRA drivers (e.g. NVIDIA's) implement GPU-specific features like MIG
  partitioning/sharing through this API rather than the classic device-plugin model.
  **Correction (2026-07-13), per `2026-07-generative-ai-on-kubernetes-gpu-production-patterns.md`**:
  while the core DRA *API* is GA, **NVIDIA's own DRA driver is still a technical
  preview as of early 2026, not supported for production** — the practical, still-current
  production standard remains device plugins + label-based scheduling, not DRA, despite
  the API itself being stable.
- **Topology-aware placement beyond basic taint/toleration**: NVIDIA GPU Feature
  Discovery (part of the GPU Operator) plus Kubernetes Node Feature Discovery (NFD)
  auto-label nodes with GPU/interconnect topology; schedulers/queueing systems (e.g.
  Kueue's topology-aware scheduling) consume those labels to co-locate pods on GPUs with
  fast NVLink paths rather than PCIe-only ones. One secondary-source case study
  (Mirantis, not independently verified here) reported ~30% training-time reduction on
  an 8-GPU ResNet-50 job from NVLink-aware co-location — a single data point, not a
  general guarantee.

## Implications for vLLM/k8s tuning

- This repo's current studies (single A10G per pod, `tensor_parallel_size` pinned to 1)
  don't need any of MIG/time-slicing/MPS/DRA today — but the moment a future study
  wants **multiple replicas sharing one GPU** (backlog #4/H4) or **multi-GPU
  tensor-parallel** on a shared node, which sharing mechanism (if any) the target
  cluster has becomes a hard constraint on what's even possible, not just a performance
  knob. Confirm with the cluster owner before assuming any of these are available —
  ties into the existing "confirm GPU-sharing scheduler" debt item in `ROADMAP.md`.
- **MIG's NVLink limitation is a hard blocker for TP≥2 within MIG slices** — if a future
  study needs multi-GPU TP *and* fractional GPU allocation on the same hardware, MIG
  alone can't deliver both; time-slicing/MPS (weaker isolation) or full-GPU-per-replica
  would be the fallback.
- DRA is new enough (GA Sept 2025) that its actual availability depends on the
  Kubernetes version installed on the target cluster (this repo's `nvidia-smi`/cluster
  version wasn't checked as part of this note) — worth confirming cluster K8s version
  before assuming DRA-based fractional GPU requests are usable.

## Which Akamas parameters to explore

N/A — this is entirely infra/cluster-setup, not a tunable vLLM/Akamas parameter. It
sharpens the existing `ROADMAP.md` debt item ("confirm whether the target cluster has a
GPU-sharing scheduler") by naming the concrete options to check for (GPU Operator +
time-slicing/MPS/MIG config, or a DRA driver) and the concrete Kubernetes version
threshold (DRA GA at v1.34) — worth a follow-up question in `ROADMAP.md` section A if
backlog #4 gets scheduled.
