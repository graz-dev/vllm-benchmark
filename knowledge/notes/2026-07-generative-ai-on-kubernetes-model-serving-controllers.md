<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Generative AI on Kubernetes — Model Servers and Serving Controllers (KServe vs. Ray Serve/KubeRay)

**Source:** *Generative AI on Kubernetes: Operationalizing Large Language Models* by
Roland Huß and Daniele Zonca (O'Reilly, 2026), Chapter 1 "Deploying Models"
(`knowledge/sources/Generative AI on Kubernetes.pdf`, pages 3-31).
**Date distilled:** 2026-07-13

## Problem addressed

This repo's studies deploy vLLM via a hand-written Kubernetes `Deployment` (manual
approach). This chapter surveys the alternative model servers (vLLM, TGI, llama.cpp,
NVIDIA NIM, SGLang) and, more importantly, the **serving-controller** layer above them —
KServe and Ray Serve/KubeRay — that abstract away exactly the manual-Deployment
complexity this repo's own template currently hand-codes (GPU tolerations, PVC wiring,
model-specific args).

## Levers / parameters touched

Not vLLM CLI flags — serving-platform/tooling choice: which model server (vLLM vs. TGI
vs. llama.cpp vs. NVIDIA NIM vs. SGLang), and which serving controller (none/manual vs.
KServe's `InferenceService`+`ServingRuntime` vs. KServe's newer `LLMInferenceService` vs.
Ray Serve/KubeRay's `RayService`).

## Key results

- **Model server landscape**: vLLM (Linux Foundation AI & Data project, 50+ model
  architectures, OpenAI-compatible server); Hugging Face TGI (now backend-pluggable:
  native CUDA, TensorRT-LLM, llama.cpp for CPU, AWS Neuron — one API, different
  backends, but tuning options vary per backend); llama.cpp (C++, GGUF format, built
  for resource-constrained/edge use via Ollama/Ramalama/LM Studio, not a large-scale
  production target); **NVIDIA NIM** (curated per-model-family container images,
  auto-selects the optimal backend with preference order
  **TensorRT-LLM > vLLM > SGLang** based on available pre-optimized engines, and — most
  relevant to this repo's own pain point — **caches the downloaded model on a
  PersistentVolume so subsequent replica creations/restarts skip the download**,
  explicitly framed as solving "one of the major pain points of model serving for
  LLMs: loading time"); SGLang (RadixAttention — a radix-tree KV-cache structure for
  efficient prefix search/reuse across requests, notably strong for repeated-context
  workloads like agents or structured-prompt reuse).
- **The manual-Deployment approach** (what this repo's studies currently do) requires
  explicitly managing: GPU resource limits/requests, HF token secrets, a PVC for model
  cache, taints/tolerations for GPU nodes, and model-specific startup args — the book
  frames this complexity multiplying with every new model as *exactly* the reason
  serving controllers exist.
- **KServe** (CNCF project, originally KFServing under Kubeflow) has three deployment
  modes: **Knative** (most capable — autoscaling/rollout/traffic via Knative+Istio, every
  model becomes a `KnativeService`), **Standard** (no extra dependencies, one plain
  Kubernetes `Deployment` per model — renamed from "RawDeployment" in KServe 0.16), and
  **ModelMesh** (high-density multi-model serving via dynamic load/unload — explicitly
  **not applicable to generative AI**, since LLMs are too large/complex to run many
  copies per node the way ModelMesh assumes). KServe 0.16 introduced a new
  **`LLMInferenceService`** CRD (built on Standard mode) specifically for LLM-scale
  deployments — it adds a `router` section (gateway + KV-cache-aware `scheduler`) and
  native `parallelism` config (`tensorParallelism`, plus data/expert parallelism), and
  explicitly points at the **llm-d project** for its distributed-inference patterns —
  confirming the connection this knowledge base's own llm-d note draws. The book's own
  comparison table: `InferenceService`+`ServingRuntime` targets predictive AI (small/
  medium models, single-node, basic load balancing), while `LLMInferenceService`+
  `LLMInferenceServiceConfig` targets generative AI (7B-405B+ models, multinode
  disaggregated serving, KV-cache-aware routing, native TP/DP/EP support).
- **Ray Serve/KubeRay**: Ray is a general Python-first distributed-computing framework
  (Task/Actor/Object/Placement Group primitives) with Ray Serve as its model-serving
  layer — deployments are defined directly in Python (`@serve.deployment` decorator),
  which is friendlier to data scientists but means a Ray Cluster (head node + worker
  nodes) isn't Kubernetes-native by design. **KubeRay**'s `RayService` CRD bridges this,
  managing a multinode Ray Cluster *and* its Ray Serve application as one Kubernetes
  resource. Trade-off vs. KServe, per the book's own framing: KServe integrates natively
  with Kubernetes primitives (familiar to platform operators, but needs extra components
  for autoscaling); Ray gives a Python-first dev experience with built-in distributed
  serving, but introduces its own orchestration layer that partially overlaps with
  Kubernetes, adding operational complexity when debugging.

## Implications for vLLM/k8s tuning

- **Directly relevant to this repo's own model-loading pain** (documented in this
  repo's own deployment template comments: "Model loading takes 5-15 minutes on first
  start"): NVIDIA NIM's PVC-based model-caching pattern is architecturally the same
  mechanism this repo's studies already use (a `vllm-model-cache` PVC) — the book frames
  it as *the* standard fix for this exact problem, confirming this repo's existing
  approach rather than suggesting a different one. Worth noting for future studies:
  Modelcars/OCI-image-based model distribution (covered in this book's Chapter 2, not
  yet distilled here) is a named alternative worth a follow-up note if PVC-based caching
  ever becomes a bottleneck.
- **This repo's studies are squarely in "Standard mode, manual Deployment" territory**
  (single model, single replica, no controller) — the book explicitly validates this as
  a reasonable starting point ("Starting with manual deployments before adopting
  controllers remains valid for early-stage projects... helps diagnose issues when
  abstractions leak"), not something to feel behind on.
- **If a future study needs multi-replica or KV-cache-aware routing** (backlog #4/H4),
  KServe's `LLMInferenceService` is a concrete, CNCF-native alternative to standing up
  llm-d directly — both ultimately rely on the same underlying Gateway API Inference
  Extension patterns this knowledge base's llm-d note describes, so the choice is really
  "KServe's opinionated CRD wrapper" vs. "llm-d's own toolchain," not two unrelated
  options.

## Which Akamas parameters to explore

N/A — this is a serving-platform/tooling choice made before a study starts, not a
tunable Akamas parameter. If a future study adopts KServe's `LLMInferenceService` or a
KubeRay `RayService` instead of a plain Deployment, the *vLLM* parameters this repo
already tunes (`gpu_memory_utilization`, `attention_backend`, etc.) would still apply
unchanged inside that controller's pod template — what would change is the deployment
mechanism and workflow tasks (`apply_config.sh`-equivalent), not `parametersSelection`
itself. Relevant to `ROADMAP.md`'s Q6 (llm-d) and backlog #4/H4 — worth a cross-reference
there if either of those gets scheduled.
