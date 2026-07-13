<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Generative AI on Kubernetes — Model Data Storage and Distribution Patterns

**Source:** *Generative AI on Kubernetes: Operationalizing Large Language Models* by
Roland Huß and Daniele Zonca (O'Reilly, 2026), Chapter 2 "Model Data"
(`knowledge/sources/Generative AI on Kubernetes.pdf`, pages 33-76).
**Date distilled:** 2026-07-13

## Problem addressed

This repo's studies use a `vllm-model-cache` PersistentVolumeClaim to avoid re-
downloading model weights from Hugging Face on every pod restart — this chapter is a
direct, sourced evaluation of that exact pattern against three alternatives (init-
container copy, Modelcars, native OCI image volume mounts), plus the model storage
*format* landscape (Safetensors/GGUF/ONNX) underneath whichever access pattern is used.

## Levers / parameters touched

Not vLLM parameters — model-data packaging/access-pattern choice: model storage format
(Safetensors/GGUF/ONNX/PyTorch state dict), model registry (Hugging Face Hub/MLflow/
Kubeflow/OCI Registry), and Kubernetes model-loading mechanism (init-container copy to
`emptyDir`, PersistentVolume/PVC, Modelcar sidecar, or native OCI image volume mount).

## Key results

- **Storage format landscape**: "weights-only" formats (PyTorch `.pt`/`.pth`, TensorFlow
  `.ckpt`) require the runtime to already know the model architecture; "mostly
  self-contained" formats bundle more but, as of 2026, **no format is fully
  self-contained** (none bundles weights + tokenizer + full architecture in one
  artifact). **Safetensors** (Hugging Face, 2021) is now the default weight format for
  large models on Hugging Face — deliberately excludes arbitrary code execution
  (unlike PyTorch's pickle-based format, a real security fix, not just a performance
  one), supports zero-copy loading and sharding (large models split across files +
  a `model.safetensors.index.json` weight-map). **GGUF/GGML** (llama.cpp project)
  focuses on quantization + CPU/edge inference, now also GPU-supported via llama.cpp
  and vLLM. **ONNX** is a mature, framework-independent format but lacks tokenizer/
  vocabulary support, making it poorly suited to LLMs specifically (better fit for
  vision models) — explicitly named as **not** what to reach for when packaging an
  LLM. The **CNCF ModelPack specification** (accepted into CNCF Sandbox, May 2025)
  is an emerging standardization effort extending the OCI image spec to AI model
  artifacts specifically.
- **Model registries** (Hugging Face Hub, MLflow, Kubeflow, OCI Registry) manage
  *metadata* and discovery, not necessarily the actual weight storage (they typically
  reference external object stores like S3) — **not directly used by this repo's
  studies today** (models are pulled straight from Hugging Face into a PVC), but
  relevant context if a future study needs private/internal model governance.
- **Four Kubernetes model-data access strategies, compared head-to-head** (the book's
  own Table 2-3, condition-labeled):

  | Approach | Storage efficiency | Access speed | Startup time | Best for | Limitations |
  |---|---|---|---|---|---|
  | Init Container Copy | Low | Fast | Slow | Single replica per node, latency-sensitive | Wastes node storage, slow initial pod creation, repeated copying |
  | **PersistentVolume** (**this repo's current approach**) | Highest | Moderate | Fast | Multiple replicas with moderate scale, external model management | Network dependency, infrastructure overhead, **struggles at hundreds of replicas** |
  | Modelcar | High | Fast | Moderate | Multiple models sharing base layers, efficient storage | Requires OCI packaging, process-namespace sharing, security considerations |
  | OCI Volume Mount | High | Fast | Moderate | Multiple models, native Kubernetes integration | Beta feature (K8s 1.35+), limited runtime support |

  **PersistentVolume mechanics directly relevant here**: `ReadOnlyMany` access mode
  (many pods mounting read-only simultaneously) is the right mode for model-serving
  PVCs — read-only additionally enables aggressive filesystem caching and eliminates
  lock contention vs. read-write mounts. `persistentVolumeReclaimPolicy: Retain`
  prevents accidental model deletion when a PVC is deleted (vs. `Delete`, which
  removes the underlying storage too). KServe's own `pvc://` storage-initializer
  scheme is a genuine **no-copy direct mount** (unlike its `s3://`/`gs://` initializers,
  which *do* copy into an `emptyDir`) — this repo's own manual Deployment mounts its
  PVC directly the same way, already matching this optimal pattern.
- **PV scaling guidance, directly calibrated by replica count**: "PVs work well for
  typical GPU-based inference deployments (10-20 replicas), where GPU costs naturally
  limit scale... 'too many pods sharing one PVC' is a real problem class, though no
  canonical threshold exists." High-performance backends (Ceph, AWS EFS, Azure Files)
  handle more concurrent load than basic NFS. **This repo's single-replica studies are
  nowhere near this scaling concern** — directly confirms the current setup needs no
  change on these grounds.
- **Modelcars** (KServe-specific technique, works on any Kubernetes version): the model
  OCI image is mounted read-only via a sidecar container that creates a symbolic link
  into a shared `emptyDir`, exposed to the main container via `/proc/<pid>/root`
  cross-container filesystem access (`shareProcessNamespace: true`) — **no data copy at
  all**, <10MB memory overhead for the modelcar sidecar itself. Real drawbacks: startup
  race (serving runtime may start before the model is linked, mitigated by Kubernetes
  native sidecar support since 1.28), a genuine **security consideration**
  (`shareProcessNamespace` exposes all containers' process namespaces to each other —
  explicitly flagged as risky when combined with service-mesh sidecars like Istio,
  which assume full isolation and may leak sensitive sidecar configuration), and
  multi-architecture duplication (mitigated by BuildKit/umoci/skopeo manifest lists).
- **Native OCI image volume mounts** (Kubernetes 1.31+ beta, no symlink/namespace-
  sharing hacks needed — the successor to Modelcars): pods mount an OCI image directly
  as a volume, with `subPath` support to expose only a model subdirectory. As of early
  2026, real limitations remain: **CRI-O v1.33+ has full support; containerd needs
  v2.2.0+ for beta support** (v2.1.0+ only basic); feature gates are still off by
  default; volumes are **read-only only** (no write-back layer); only whole-directory
  mounts, not individual files. The book frames Modelcars as "a bridging technology
  with a smooth upgrade path" to this — not a dead end, but not yet the final answer.

## Implications for vLLM/k8s tuning

- **This repo's own model-caching PVC pattern is validated as the standard, well-suited
  approach for its actual scale** (single replica, single study at a time) — the
  book's own guidance places PVC-based caching squarely in its sweet spot (moderate
  replica counts, external model management), and this repo's `ReadOnlyMany`-style
  usage (implicitly, given no concurrent writers) matches the book's own
  recommendation. No change needed on these grounds.
- **If a future study scales to many concurrent replicas** (backlog #4/H4 territory),
  this source gives a concrete signal to watch for: PVC/NFS-style storage becoming a
  bottleneck "at hundreds of replicas" — at that point, Modelcars or (once mature)
  native OCI image volume mounts become the better-suited pattern, per the book's own
  comparison table.
- **Model storage format choice is orthogonal to this repo's current scope** (it pulls
  whatever format the chosen Hugging Face model ships in — currently Safetensors for
  Qwen2.5-7B-Instruct, matching the book's own observation that Safetensors is now the
  Hugging Face default) — no action needed unless a future study specifically wants to
  benchmark a GGUF-quantized model via llama.cpp instead of vLLM.

## Which Akamas parameters to explore

N/A — this is model-data packaging/distribution, not a tunable vLLM/Akamas parameter.
The one operationally relevant, sourced fact for this repo: PersistentVolume-based
model caching (already in use) is confirmed appropriate at this repo's current scale,
with a concrete "hundreds of replicas" ceiling to watch for if that scale ever changes —
worth a light cross-reference from `ROADMAP.md`'s backlog #4 discussion if/when it's
scheduled, not added here since it doesn't change anything actionable today.
