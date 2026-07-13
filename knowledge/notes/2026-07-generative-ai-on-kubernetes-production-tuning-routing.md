<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Generative AI on Kubernetes — Production Tuning, Startup Time, LLM-Aware Routing, and Disaggregated Serving

**Source:** *Generative AI on Kubernetes: Operationalizing Large Language Models* by
Roland Huß and Daniele Zonca (O'Reilly, 2026), Chapter 4 "Running in Production"
(`knowledge/sources/Generative AI on Kubernetes.pdf`, pages 119-152).
**Date distilled:** 2026-07-13

## Problem addressed

This chapter covers five production concerns: model selection/compression, vLLM
runtime parameter tuning, autoscaling, **optimizing vLLM startup time** (directly
relevant — this repo's own template documents "5-15 minutes" model load as a known
cost per experiment), LLM-aware routing, and disaggregated serving. The startup-time
section is the most actionable for this repo specifically: every Akamas experiment in
`studies/0-explorative` pays this cost once per trial, so anything that shrinks it
directly speeds up this repo's own iteration loop, independent of any vLLM parameter
tuned.

## Levers / parameters touched

vLLM runtime flags discussed directly: `gpu-memory-utilization`, `max-model-len`,
`max-num-seqs`/`max-num-batched-tokens`, `tensor-parallel-size`, `pipeline-parallel-
size`, `data-parallel-size`, `cpu-offload-gb` (explicitly discouraged), and model-
loading flags `--load-format runai_streamer`/`tensorizer` +
`--model-loader-extra-config`. Infra/tooling choices: autoscaler (HPA/KPA/KEDA),
image-pull policy, model-loading accelerator (Run:ai Model Streamer/CoreWeave
Tensorizer/fastsafetensor), and routing/gateway component (Gateway API Inference
Extension, Envoy AI Gateway, disaggregated-serving stack).

## Key results

### Model tuning/compression
- Quantization (FP8/INT8) can more than halve model size while **recovering >99% of
  original accuracy when properly calibrated** — vLLM has native quantized-kernel
  support via the `llmcompressor` project; Red Hat AI's Hugging Face org ships
  pre-compressed, pre-validated models as a lower-risk alternative to compressing
  yourself.
- **Memory sizing formula** (book's own worked example, 8B model, float16, 2048
  context, batch size 1): baseline = params × bytes/param (8B × 2 = 16 GB) + ~300MB-2GB
  infra overhead + activation memory (200-300MB at short sequences, **grows
  quadratically with sequence length**) + output-tensor cost (vocab size × sequence
  length × batch size) → ~17.3 GB total for this example. **Batch size 10 nearly
  doubles this to >28 GB** — a concrete, sourced confirmation that KV-cache/activation
  memory scales with concurrency, not just model size.
- `gpu-memory-utilization` default is **0.9** specifically as an OOM safety margin from
  earlier, less-stable vLLM versions — the book states **"vLLM stability has improved
  [so] it's now often safe to increase this value closer to 1.0."** Worth noting against
  this repo's own narrower `[0.85, 0.95]` domain (calibrated from a real observed OOM in
  `studies/0-explorative`, not from this general guidance) — the two aren't
  contradictory (this repo's narrowing is empirically grounded for its specific
  model/hardware, this source's guidance is a general default), but worth knowing the
  book leans toward permissiveness here.
- `cpu-offload-gb` (spilling part of the model to CPU RAM) is **explicitly discouraged
  for production** — "significantly impacts throughput" and loses GPU-specific kernel
  optimizations. This repo doesn't tune this parameter — confirmed as correctly
  excluded, not an oversight.

### Autoscaling
- **HPA doesn't fit LLM workloads** (same conclusion as this knowledge base's existing
  autoscaling note, now with a second independent source): monitors CPU/memory, which
  don't reflect GPU-bound LLM load.
- **Knative Pod Autoscaler (KPA)**: time-windowed request-based scaling (default
  "stable" mode uses a longer window; "panic" mode a shorter one for fast reactions) —
  works natively with KServe's Knative mode, but the book flags the same core problem
  as this knowledge base's existing note: **request count doesn't correlate with
  workload** (one request can generate 10 tokens, another 10,000) and multi-minute GPU
  cold-starts make reactive scaling impractical without additional tuning.
- **KEDA** (works with KServe's Standard mode) queries **vLLM's own Prometheus
  metrics directly** — `vllm:num_requests_waiting` for queue depth, or
  `vllm:time_to_first_token_seconds`/`vllm:time_per_output_token_seconds` for latency
  SLOs — via a `PodMetric` (query the pod directly, lower latency) or `External` (query
  an aggregating backend like Prometheus, more flexible — can join metrics across
  replicas) source type.
- **llm-d's Workload Variant Autoscaler (WVA)** — a newly-surfaced detail extending
  this knowledge base's existing llm-d note: WVA scales based on **actual per-request
  work** (accounting for the fact different requests generate different token counts)
  against latency targets, rather than raw request/CPU counts — a more sophisticated
  successor to KEDA's simpler metric-threshold model, specifically for LLM workloads.

### Optimizing vLLM startup time — directly actionable for this repo
Six-phase breakdown of what actually takes time (runtime image pull → model retrieval/
mounting → runtime start [~1 second] → model loading → engine warmup → exposing the
API) — **model retrieval/mounting and model loading are the two phases worth
optimizing**, "reducing time to scale up vLLM from many minutes to tens of seconds":
- **Image pull**: avoid `imagePullPolicy: Always` (use `IfNotPresent` or pre-pull);
  pin exact digests (`vllm/vllm-openai@sha256:...`), not `latest`, for reproducibility
  — this repo's own template already pins a specific tag (`v0.22.0`), not `latest`,
  matching this recommendation, though not by digest.
- **Model retrieval/mounting**: direct HF/S3 download is "inefficient, often taking
  minutes"; **PVC and OCI-image mounting avoid the copy step entirely** (confirms this
  repo's own PVC-based approach, per the companion model-data-storage note).
  **KServe's "local model cache" option** makes HF/S3 downloads "effectively
  equivalent to using a PVC" when combined with fast NVMe storage — an alternative
  worth knowing about, though not directly applicable to this repo's manual-Deployment
  (non-KServe) setup.
- **Model loading — the single most directly actionable finding for this repo**:
  three named vLLM-integrated projects specifically speed up this phase:
  **Run:ai Model Streamer** (`--load-format runai_streamer`, no repackaging required,
  concurrent multi-threaded loading via
  `--model-loader-extra-config '{"concurrency":16}'` — the book calls this "the
  easiest option to experiment with" since it needs no model repackaging), CoreWeave
  Tensorizer, and fastsafetensor (both require pre-serializing the model in a specific
  format first). NVIDIA GPUDirect Storage (direct NVMe→GPU-memory path, bypassing the
  CPU) is named as the infrastructure-level complement. **This is a concrete,
  low-effort lever this repo's own studies could test**: since every Akamas experiment
  reloads the model from scratch, `--load-format runai_streamer` with concurrent
  loading could shrink the per-experiment model-load overhead without touching any
  vLLM *parameter under test* — worth a manual verification run analogous to this
  session's earlier `attention_backend`/`kv_cache_dtype` checks, not yet tried here.
- **Engine warmup**: vLLM captures CUDA/HIP graphs during warmup to avoid per-kernel-
  launch CPU overhead — necessary for high-throughput serving but adds to total
  time-to-ready; this is separate from (and after) model loading.

### LLM-aware routing and the Gateway API Inference Extension (GIE)
- Round-robin (Kubernetes' default LB strategy) doesn't fit LLM serving for the same
  reason autoscaling doesn't: request cost is unpredictable and vLLM's own
  `vllm:num_requests_waiting` metric is the signal a smarter router needs.
- **Prefix-aware routing**: routing requests with shared context (multi-turn chat,
  repeated tool-call prefixes) to the *same* replica exploits KV-cache reuse across
  requests — the same mechanism SGLang's RadixAttention exploits internally (per this
  knowledge base's earlier serving-controllers note), here applied at the cluster
  routing layer instead of within one instance.
- **Gateway API Inference Extension (GIE)**, incubated by Kubernetes SIG's
  WG-Serving: extends the (already-stable, general-purpose) Kubernetes Gateway API
  with LLM-specific resources. **`InferencePool`** (stable v1): a group of pods
  sharing compute config/accelerator/base model, with a `endpointPickerRef` pointing
  at an Endpoint Picker service that implements the actual routing logic via Envoy's
  External Processing (`ext_proc`) gRPC protocol. **`InferenceObjective`** (alpha v2,
  replaced the earlier `InferenceModel` resource): defines serving priority across
  pools, so higher-priority traffic can be handled preferentially. One notable named
  Endpoint Picker implementation: **llm-d's own `inference-scheduler`** — directly
  ties this knowledge base's existing llm-d note to this GIE mechanism explicitly.
  Two competing/complementary AI-gateway projects built on GIE: **Envoy AI Gateway**
  (adds token-based rate limiting, security) and **Kuadrant** (Kubernetes-native token
  quota policy).
- **AI gateways enable Model-as-a-Service (MaaS)** architectures — multi-tenant model
  access with token-based (not request-based) rate limiting and quotas, since a single
  request's cost varies 1000x by token count.
- **LoRA-adapter serving** breaks the usual "one model per endpoint" assumption: vLLM
  natively serves a base model plus multiple LoRA adapters under one endpoint
  (`--enable-lora --lora-modules <name>=<path>`), each individually selectable per
  request (`"model": "<adapter-name>"` in the request body) — GIE's `InferencePool`
  selector/routing logic is explicitly designed to route to the right pod given this
  multi-adapter-per-pod reality.

### Disaggregated serving
- **Distinct from ordinary multi-replica/autoscaled deployment** — this is
  appliance-like, purpose-built for very-large-scale, few-models-per-cluster
  deployments, not this repo's current single-model/single-replica scope.
- **Network bandwidth is the hard constraint**: ordinary pod networking (~10-20 Gbps
  Ethernet) is roughly an order of magnitude below what distributed KV-cache transfer
  needs (~500-600 Gbps); RDMA/RoCE/InfiniBand can reach ~800 Gbps, NVLink/NVSwitch
  (intra-node) can reach Tbps.
- **Distributed KV cache**: two named projects, **LMCache** ("Redis for LLMs," an API
  to cache/reuse KV blocks externally — most valuable for long-prompt/RAG workloads
  where re-running prefill on every request is wasteful) and **NVIDIA Inference Xfer
  Library (NIXL)** (a lower-level point-to-point transfer library across
  GPU/CPU/storage memory tiers — flexible enough to use even without full
  disaggregation, e.g. to extend KV cache into CPU RAM).
- **Disaggregated prefill**: splits prefill (compute-bound, impacts TTFT) and decode
  (memory-bound, impacts ITL) onto separate, independently-scaled pod pools — lets a
  prompt-heavy workload scale prefill capacity without over-provisioning decode
  capacity (or vice versa). Requires the distributed KV cache mechanism above (prefill
  computes the KV cache, decode needs it transferred) plus a routing component aware
  of both pools.
- **llm-d's full architecture** (Figure 4-4 in source) composes all of the above:
  Gateway API → `LLMInferenceService` → inference-scheduler (Endpoint Picker) + KV
  cache indexer, routing to separate decode/prefill pools each running vLLM+LMCache+
  NIXL, coordinated via LMCache metadata. NVIDIA Dynamo is named as the main
  alternative, "specialized and deeply integrated with NVIDIA hardware" vs. llm-d's
  hardware-agnostic, open-ecosystem approach — directly extends this knowledge base's
  existing llm-d and Dynamo Planner notes with the concrete disaggregation-specific
  comparison.
- Disaggregated prefill's core topology idea originated in the **Mooncake project**,
  later adopted by both NVIDIA Dynamo and llm-d — useful provenance if a future study
  ever needs to trace this pattern back further.

## Implications for vLLM/k8s tuning

- **Most directly actionable finding: model-loading acceleration** (Run:ai Model
  Streamer, `--load-format runai_streamer`) is a genuine, low-effort candidate to speed
  up this repo's own experiment iteration time, independent of anything already being
  tuned — worth a manual verification run before adopting.
- **Autoscaling, LLM-aware routing, and disaggregated serving are all N/A for this
  repo's current single-replica scope** — confirmed by multiple independent sections
  of this chapter, consistent with this knowledge base's existing notes on the same
  topics. They become relevant together, as one connected stack (not independently),
  once backlog #4/H4-H6 reach multi-replica territory.
- **This repo's `gpu_memory_utilization` domain `[0.85, 0.95]`** is narrower than this
  source's general "often safe near 1.0" guidance — not a contradiction (this repo's
  narrowing is calibrated from a real observed OOM on this specific model/GPU, a
  stronger form of evidence than a general default's rationale), but worth knowing this
  source would consider even less-conservative values plausible in principle.
- **LoRA-adapter serving is not relevant to this repo's studies** (single base model,
  no fine-tuned variants) — noted for completeness, not actionable here.

## Which Akamas parameters to explore

- **`vLLM.gpu_memory_utilization`**, **`vLLM.max_model_len`**, **`vLLM.max_num_seqs`**/
  **`max_num_batched_tokens`**, **`vLLM.tensor_parallel_size`** — all already modeled
  and tuned/pinned in this repo; this chapter reinforces their importance without
  suggesting new bounds beyond what's already calibrated.
- **Model-loading flags (`--load-format`, `--model-loader-extra-config`) are not
  currently modeled by the installed vLLM optimization pack** — if the Run:ai Model
  Streamer verification mentioned above proves useful, this would be a concrete new
  parameter to request from whoever manages the pack (though it likely belongs as a
  pinned/fixed choice rather than a tuned dimension, since it affects loading time, not
  the goal metric this repo's studies optimize for).
- **Autoscaler class (KEDA/KPA), Gateway API Inference Extension resources
  (`InferencePool`/`InferenceObjective`), and disaggregated-serving components
  (LMCache/NIXL)** are N/A — cluster/topology-level choices made before a study
  starts, not vLLM parameters, consistent with this knowledge base's existing llm-d
  and autoscaling notes.
