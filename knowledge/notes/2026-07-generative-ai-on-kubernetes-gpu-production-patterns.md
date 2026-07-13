<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Generative AI on Kubernetes — GPU Production Patterns (Device Plug-ins, DRA, MIG/Time-Slicing, Multi-GPU Parallelism)

**Source:** *Generative AI on Kubernetes: Operationalizing Large Language Models* by
Roland Huß and Daniele Zonca (O'Reilly, 2026), Chapter 3 "Kubernetes and GPUs"
(`knowledge/sources/Generative AI on Kubernetes.pdf`, pages 81-117).
**Date distilled:** 2026-07-13

## Problem addressed

This deepens and, in one place, **corrects** this knowledge base's own earlier note
(`2026-07-kubernetes-gpu-scheduling-patterns.md`): full GPU-discovery-to-multi-GPU-
inference walkthrough by two Red Hat OpenShift AI engineers, with concrete production
numbers this repo didn't have before (NVLink/NVSwitch bandwidth figures, tensor-
parallelism communication-overhead percentages, near-linear vs. diminishing multi-GPU
scaling).

## Levers / parameters touched

Cluster/infra setup, not vLLM parameters: Node Feature Discovery (NFD) + GPU Feature
Discovery (GFD) labels, device-plugin resource requests, node affinity/taints, Dynamic
Resource Allocation (DRA) `ResourceClaimTemplate`s, NVIDIA GPU Operator `ClusterPolicy`
(time-slicing vs. MIG strategy), and multi-GPU parallelism strategy (data/tensor/
pipeline parallelism) plus pod affinity/anti-affinity for placement.

## Key results

- **Correction to this knowledge base's own prior note**: DRA's core API is GA and
  stable since Kubernetes **v1.34**, confirming the earlier note — **but this book adds
  that the NVIDIA GPU DRA *driver* itself is still a technical preview, not supported
  for production as of early 2026**, and that partial GPU requests / fine-grained MIG
  partitioning / topology-aware scheduling via DRA are still driver- and
  platform-dependent and maturing. Practical takeaway sharper than the earlier note's:
  **the classic device-plugin + label-based scheduling model remains the
  production-ready standard for GPU scheduling today**, not DRA, even though DRA's
  Kubernetes-side API itself is GA.
- **NFD vs. GFD**: NFD (generic, DaemonSet-based) labels basic hardware
  (`feature.node.kubernetes.io/pci-0302_10de.present: "true"` for "has an NVIDIA GPU").
  NVIDIA's own **GPU Feature Discovery (GFD)**, deployed as part of the GPU Operator,
  adds detailed GPU-specific labels: `nvidia.com/gpu.count`, `nvidia.com/gpu.product`
  (model, e.g. `A100-SXM4-40GB`, with a `-SHARED` suffix when time-sliced),
  `nvidia.com/gpu.memory`, `nvidia.com/mig.capable`, `nvidia.com/gpu.compute.major/minor`
  (CUDA compute capability) — these enable `nodeSelector`/affinity rules precise enough
  to target a specific GPU generation or memory size, not just "has a GPU."
  Confirms (independently) this repo's own compute-capability findings from the
  `0-explorative` study incidents (Ampere = compute capability 8.6, checked via
  `nvidia.com/gpu.compute.major/minor`-equivalent facts derived manually there).
- **Sub-GPU sharing — time slicing vs. MIG, explicitly evaluated for LLM relevance**:
  time slicing (software temporal sharing, no memory isolation, configured via a
  `ConfigMap` + `replicas: N` oversubscription factor) is explicitly called out as
  **"might not be so useful in the context of LLMs, which are typically so large that
  they need to allocate the full physical memory offered by a GPU"** — directly
  relevant confirmation that this repo's single-A10G, single-replica studies correctly
  don't need this mechanism. MIG (hardware partitioning, A100/A30/H100/Blackwell
  B100/B200, up to 7 isolated instances per card, e.g. `1g.5gb` = 1 compute slice + 5GB)
  gives real isolation but is similarly framed as best suited to **small/many models**
  (7 language models at ~5GB each), not this repo's single large-model-per-GPU case —
  "if you have a large model (that needs >40 GB, for instance), MIG won't help — you
  need the full GPU or multiple GPUs."
- **Multi-GPU parallelism taxonomy, with concrete overhead numbers**: **data
  parallelism** (N full model replicas, one per GPU, via a Kubernetes Service load
  balancer — no per-query latency improvement, only throughput/QPS) vs. **model
  parallelism** — **tensor parallelism** (splits computation *within* each layer across
  GPUs, reduces per-GPU memory *and* per-token latency, but **communication overhead can
  consume 50-70% of inference time if the interconnect is poorly partitioned** — this is
  why it's confined to single-node, high-bandwidth-interconnect setups) vs. **pipeline
  parallelism** (splits *layers* across GPUs/nodes, only one activation handoff per
  pipeline stage — far more tolerant of slow/multinode networking, but doesn't improve
  and can *increase* single-request latency due to sequential-stage bubble overhead).
  **Practical scaling numbers**: within one node, ~4 GPUs deliver "approximately three
  and a half times the throughput of one GPU for a well-optimized model" (near-linear
  but not perfectly linear); going multinode can show diminishing returns if the network
  becomes the bottleneck, and the slowest node dictates the pace of collective
  operations (all-reduce, etc.) — one busy/GC-paused node can stall the whole pipeline.
- **Interconnect hardware specifics**: NVLink 5.0 (Blackwell) delivers up to **1.8
  TBps bidirectional bandwidth per GPU** (18 links @ 100 GBps) — 2x NVLink 4.0 (H100,
  900 GBps) and >14x PCIe Gen5. NVSwitch extends NVLink into a fully-connected mesh
  (NVSwitch 4.0: 72 ports/chip, 14.4 TBps switching capacity per chip). Cross-node
  communication instead uses InfiniBand/RoCE with GPUDirect RDMA (bypasses the CPU for
  GPU-to-GPU transfers across nodes) — inter-node bandwidth (e.g. 100-Gbit Ethernet ≈
  12.5 GBps) is roughly **two orders of magnitude slower** than intra-node NVLink,
  the concrete reason tensor parallelism is single-node-only in practice while pipeline
  parallelism tolerates multinode.
- **Multi-GPU failure semantics**: a single-node multi-GPU pod failing is a normal pod
  restart; a **multinode model-parallel** deployment losing any one participating pod
  disrupts the *entire* inference job (incomplete model shard) and typically requires
  restarting the whole group — this all-or-nothing recovery pattern is named **gang
  scheduling** (the book's Chapter 7 covers this in depth, not yet distilled in this
  knowledge base). `PodDisruptionBudget`s are named as the mitigation for *planned*
  maintenance disruptions in this scenario (checkpointing is framed as more relevant to
  training than to stateless inference serving).
- **GPU memory defragmentation**: as models load/unload or sequence lengths vary,
  the GPU memory allocator can fragment into many small free chunks rather than one
  contiguous block — can cause OOM even when enough *total* free memory exists, just not
  contiguously. Mitigations named: pre-allocate large blocks at startup (load all weights
  once, use memory pools for scratch space), PyTorch's "expandable segments" feature, and
  — notably — **the book frames vLLM's own PagedAttention as fundamentally a
  defragmentation technique for the KV cache specifically**, not just a throughput
  optimization.

## Implications for vLLM/k8s tuning

- **This repo's current single-A10G/single-replica scope needs none of MIG/time-slicing/
  DRA** — confirmed directly by this source's own framing (LLMs are "too large" for
  sub-GPU sharing to help). This is useful negative confirmation, not just a gap to fill.
- **Directly extends `ROADMAP.md`'s H5/H6 hypotheses** (tensor_parallel_size "minimum
  that fits" and TP×max_num_seqs coupling): this source's 50-70%-communication-overhead
  figure and single-node-only recommendation for tensor parallelism give H5 a concrete,
  sourced number to test against once a future study actually tunes
  `tensor_parallel_size` >1 — a future study could check observed communication overhead
  against this 50-70% ceiling as a sanity check on whether its interconnect is adequate.
- **Sharpens the existing "confirm GPU-sharing scheduler" `ROADMAP.md` debt item**: the
  DRA production-readiness caveat here (NVIDIA's own DRA driver is preview-only) means a
  future study should not assume DRA is a viable path yet even on a Kubernetes 1.34+
  cluster — device plugins + label-based scheduling (nodeSelector/affinity/taints) is
  still the thing to actually check for and use.
- **Gang scheduling** (Chapter 7, not yet distilled here) is directly relevant to
  backlog #4/H4's eventual multi-replica or multi-GPU work if it ever spans multiple
  nodes — flagged here as a candidate follow-up note, not distilled yet.

## Which Akamas parameters to explore

N/A — none of this chapter's content is a vLLM/Akamas-tunable parameter; it's
cluster/infra setup (device plugins, DRA, GPU Operator `ClusterPolicy`) and
architecture-level decisions (parallelism strategy, node topology) made before or
alongside a study, not inside `parametersSelection`. The one existing Akamas parameter
this reinforces is `vLLM.tensor_parallel_size` (already modeled, pinned at 1 in this
repo's current studies) — this source adds concrete overhead numbers (50-70% at worst)
to reason about before tuning it above 1 in a future multi-GPU study.
