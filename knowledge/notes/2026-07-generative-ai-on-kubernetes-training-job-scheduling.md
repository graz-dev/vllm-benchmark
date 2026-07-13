<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Generative AI on Kubernetes — Job Scheduling Optimization (Distributed Training)

**Source:** *Generative AI on Kubernetes: Operationalizing Large Language Models* by
Roland Huß and Daniele Zonca (O'Reilly, 2026), Chapter 7 "Job Scheduling Optimization"
(`knowledge/sources/Generative AI on Kubernetes.pdf`, pages 205-257).
**Date distilled:** 2026-07-13

## Scope note

**This entire chapter is framed around distributed training jobs** (`PyTorchJob`,
Kubeflow Trainer, gradient synchronization via all-reduce/all-gather, checkpoint
resumption after preemption) — not inference serving, which is this repo's only
current use case. Most of the chapter (gang scheduling's rendezvous-barrier problem,
training-specific storage sizing, Ray/PyTorch-distributed security, TensorBoard/
Kubeflow Trainer observability, Slurm/Slinky HPC bridging) has **no direct analog** in
a single-pod vLLM Deployment and is *not* distilled in depth below. Only the pieces
that plausibly transfer to inference serving are pulled out — see "Implications" for
exactly which, and why each one is conditional rather than immediately actionable.

## Problem addressed

How to schedule, network, store for, secure, and observe multi-node/multi-GPU training
jobs on Kubernetes at production scale, given that Kubernetes' default per-pod
scheduling model doesn't understand "all workers or none" (gang scheduling), GPU
interconnect topology, or multi-tenant GPU quota fairness.

## Levers / parameters touched

Not vLLM parameters — cluster/scheduler design choices: gang-scheduling mechanism
(Coscheduling plug-in / Kueue / NVIDIA KAI Scheduler / Volcano), Kubernetes Topology
Manager policy (`none`/`best-effort`/`restricted`/`single-numa-node`), network
technology for multi-GPU communication (NVLink/NVSwitch/InfiniBand/RoCE/Ethernet +
GPUDirect RDMA), and NCCL environment-variable tuning
(`NCCL_IB_HCA`/`NCCL_SOCKET_IFNAME`/`NCCL_NET_GDR_LEVEL`/`NCCL_TOPO_FILE`).

## Key results

- **Quota management / multi-tenancy (Table 7-4)**, extending the comparison already
  in [[2026-07-kubernetes-cluster-config-autoscaling-multitenancy]]: **Kueue**
  (hierarchical quota with cohort-based borrowing + preemption, admission-controller
  layer that keeps the default kube-scheduler — `ClusterQueue`/`LocalQueue`/cohort/
  `WorkloadPriorityClass` objects, `flavorFungibility.whenCanBorrow` controls
  `MayStopSearch` vs `TryNextFlavor` fallback behavior), **NVIDIA KAI Scheduler**
  (project-based GPU quotas + fair-share, full scheduler replacement, tightest
  GPU-specific integration incl. MIG/fractional GPU), **Volcano** (queue-based quotas
  with proportional allocation, also a full scheduler replacement). Common combined
  architecture: Kueue handles job-level admission/quota, a topology-aware scheduler
  (KAI/Volcano) handles actual GPU-topology-optimized placement underneath it.
- **Kubernetes Topology Manager** (Kubelet component, distinct from cluster-level
  gang/topology-aware *schedulers* covered earlier — this operates at the single-node
  level): coordinates CPU Manager and Device Manager so a pod's CPUs and GPUs are
  NUMA-local, avoiding the ~300ns cross-NUMA-socket memory-access penalty (vs. ~100ns
  local) that can matter for GPU-intensive workloads. Policies: `best-effort` (attempt
  alignment, don't enforce), `restricted` (only admit if alignable), `single-numa-node`
  (strictest, all resources from one NUMA node, reduces scheduling flexibility in
  constrained clusters). **This is a genuinely general GPU-placement concern, not
  training-specific** — applies to any multi-GPU pod, including a tensor-parallel
  inference deployment.
- **Network technology comparison for GPU communication (Table 7-5)**, concrete
  bandwidth/latency/scope figures (aligns with and sharpens the numbers already in
  [[2026-07-generative-ai-on-kubernetes-gpu-production-patterns]]): NVLink/AMD
  Infinity Fabric (900 GBps-1.8 TBps/GPU intra-node, microseconds, up to 896 GBps on
  MI300X), NVSwitch (600-900 GBps/GPU full-mesh, 8-16 GPUs/server), InfiniBand
  (200-400 GBps/port inter-node RDMA, submicrosecond, "gold standard" for large HPC
  clusters), RoCE/RoCEv2 (100-400 GBps/port, low-microsecond, needs Priority Flow
  Control/Enhanced Transmission Selection to avoid UDP/IP packet loss retransmission
  cost), standard Ethernet (10-25 GBps typical, up to 100 GBps, tens-hundreds of
  microseconds — viable for 2-8 node data-parallel jobs staying under a 15-25%
  communication-overhead-vs-compute-time ratio), GPUDirect RDMA (a 40-60% latency
  *reduction* layered on InfiniBand/RoCE, not a standalone fabric). Per-parallelism-
  strategy guidance: data parallelism tolerates RoCE/Ethernet at smaller node counts;
  tensor parallelism needs NVLink/NVSwitch (single-node) or InfiniBand (small 2-4 node
  clusters) because of submicrosecond-latency-sensitive per-layer all-gather/
  reduce-scatter; pipeline parallelism tolerates RoCE/Ethernet (point-to-point,
  higher latency-tolerant).
- **Multus CNI + NCCL wiring mechanics** for attaching secondary high-performance
  network interfaces to training pods (`NetworkAttachmentDefinition` CRDs, `ib0`
  InfiniBand device exposure, `rdma/hca` resource requests, `IPC_LOCK` capability for
  pinned RDMA memory buffers) — concrete example of what "configure the network" means
  operationally, not just a bandwidth number.
- **Training Job Security (Ray, PyTorch Distributed)**: both frameworks ship with
  **no built-in authentication/authorization or encryption by default** — explicitly
  documented by their own maintainers as "intended for internal communication only,"
  "not built for use in untrusted environments." Any process with network access to a
  Ray cluster or PyTorch Distributed job can execute arbitrary code with full
  privileges (compounded by Ray's cloudpickle-based serialization, a known-insecure
  mechanism). Mitigation is entirely at the infrastructure layer: Kubernetes
  `NetworkPolicy` deny-all-by-default + explicit allow rules scoped by label selectors
  (`ray.io/cluster`, a `pytorch-job-name` label), optional TLS layered on top (Ray
  supports it via `rayStartParams`; PyTorch distributed has no built-in TLS option at
  all, network isolation is the *only* control).
- **Storage for training** (Table 7-6: NFS/Ceph-CephFS-GlusterFS/cloud file storage/
  object storage/local NVMe) is sized very differently from inference model-loading:
  rule of thumb `2 × base_model_size + checkpoint_overhead`, driven by *frequent
  mid-training checkpointing* for preemption recovery, not read-only model weights —
  a different problem from the PVC/Modelcar/OCI-volume comparison already distilled in
  [[2026-07-generative-ai-on-kubernetes-model-data-storage]].
- **Lessons learned (chapter's own framing)**: gang scheduling and topology-aware
  scheduling are called "nonnegotiable" for training because the default per-pod
  scheduler model causes resource fragmentation on partial allocations; security and
  storage architecture "cannot be retrofitted after deployment."

## Implications for vLLM/k8s tuning

- **Gang scheduling itself is not relevant to this repo**: `studies/0-explorative` (and
  every study so far) runs a single-pod vLLM Deployment — there is no "all-or-nothing"
  multi-worker rendezvous barrier to protect, so Coscheduling/Kueue/KAI/Volcano's gang-
  scheduling features solve a problem this repo doesn't have. This narrows (not just
  reconfirms) the earlier open question about whether gang scheduling matters for this
  repo — it doesn't, unless a future study runs a genuinely multi-node vLLM deployment.
- **Topology-aware placement and the Kubernetes Topology Manager *do* plausibly apply**
  to a future single-node multi-GPU tensor-parallel study (backlog #4/H5/H6 territory,
  `tensor_parallel_size > 1`): NUMA-local CPU/GPU/NIC placement and the interconnect
  technology (NVLink/NVSwitch vs. PCIe-only) directly affect the 50-70%-communication-
  overhead figure already in `ROADMAP.md`'s H5. This is a node-*provisioning* concern
  (verify NUMA topology and interconnect before the study, not something Akamas tunes),
  distinct from gang/quota scheduling.
- **The Kueue/KAI Scheduler/Volcano quota-management comparison is a multi-tenancy
  concern**, relevant only if this repo's cluster is ever shared with other GPU
  workloads (training or otherwise) competing for the same GPUs — same conditionality
  already flagged in [[2026-07-kubernetes-cluster-config-autoscaling-multitenancy]],
  now with the specific quota/borrowing/preemption mechanics to reference if that
  backlog item is ever picked up.
- **The Ray/PyTorch-distributed security gap is a real, transferable caveat with one
  specific condition**: vLLM itself can use Ray as its distributed executor backend for
  multi-node tensor/pipeline-parallel serving. If a future study ever runs vLLM in that
  configuration, this chapter's warning applies directly — Ray's lack of built-in
  auth/encryption is not fixed by vLLM sitting on top of it, and the same
  NetworkPolicy-deny-all mitigation pattern would be needed. Not relevant to any
  single-node study run so far.
- **Training-specific storage sizing, TensorBoard/W&B/Kubeflow Trainer observability,
  and Slurm/Slinky HPC bridging have no bearing on this repo's inference-serving
  studies** — flagged as read, deliberately not carried forward.

## Which Akamas parameters to explore

N/A — nothing here is a tunable vLLM/Akamas parameter. The two genuinely transferable,
non-parameter facts worth a light `ROADMAP.md` cross-reference (asking before adding,
not added here): (1) NUMA/interconnect topology as a node-provisioning prerequisite to
check before any future multi-GPU tensor-parallel study (H5/H6), and (2) the
Ray-backend security caveat, conditional on ever running vLLM's multi-node Ray executor
mode. Gang scheduling and quota-management tooling (Kueue/KAI/Volcano) remain N/A for
this repo's current single-pod-per-study scope, same conclusion as the existing
multi-tenancy note.
