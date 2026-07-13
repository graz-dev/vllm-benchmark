<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# llm-d: Kubernetes-Native Distributed vLLM Inference

**Source:** [llm-d GitHub repo](https://github.com/llm-d/llm-d),
[Red Hat Developer — llm-d Kubernetes-native distributed inferencing](https://developers.redhat.com/articles/2025/05/20/llm-d-kubernetes-native-distributed-inferencing),
[Red Hat Developer — Master KV cache aware routing with llm-d](https://developers.redhat.com/articles/2025/10/07/master-kv-cache-aware-routing-llm-d-efficient-ai-inference),
[Google Cloud Blog — Enhancing vLLM for distributed inference with llm-d](https://cloud.google.com/blog/products/ai-machine-learning/enhancing-vllm-for-distributed-inference-with-llm-d),
[vLLM Docs — llm-d integration](https://docs.vllm.ai/en/latest/deployment/integrations/llm-d/),
[Kubernetes.io — Introducing Gateway API Inference Extension](https://kubernetes.io/blog/2025/06/05/introducing-gateway-api-inference-extension/),
[AWS ML Blog — Disaggregated Inference on AWS powered by llm-d](https://aws.amazon.com/blogs/machine-learning/introducing-disaggregated-inference-on-aws-powered-by-llm-d/)
**Date distilled:** 2026-07-13

## Problem addressed

This repo's studies run a single vLLM replica on a single GPU with no request routing
layer. llm-d addresses the opposite regime: serving at scale across **many** vLLM
replicas/nodes, where request cost is highly non-uniform (long multi-turn/agentic/RAG
prompts, variable input:output ratios) and specializing hardware/pools by phase
(prefill vs. decode) or by cache locality pays off. It's an orchestration layer *on top
of* vLLM, not a replacement — the vLLM engine itself is unchanged underneath.

## Levers / parameters touched

Not vLLM CLI flags — cluster-level routing/topology policy: an **Inference Gateway
(IGW)** built on Kubernetes SIGs' Gateway API Inference Extension, adding `InferencePool`
(a pool of pods sharing model/accelerator/config) and `InferenceModel` CRDs; a
vLLM-aware scheduler/Endpoint Picker (EPP) doing prefix-cache- and load-aware routing
instead of round-robin; a KV-cache indexer giving a near-real-time view of which pods
hold which KV blocks; optional prefill/decode disaggregation via vLLM's KV Connector API
onto separately-scaled pod pools; and SLO-aware autoscaling/scale-to-zero.

## Key results

All figures below are vendor-published (Red Hat/Google/AWS), not independently
reproduced — treat as directional, condition-specific claims, not verified benchmarks:

- H100 clusters, Llama 3.1 70B, RAG/reasoning workloads: **3x lower TTFT at 4 QPS**,
  **~50% higher throughput at a fixed SLO**, **2x baseline QPS sustained under SLO**.
- Prefix-cache-aware routing alone: **3x higher output throughput, 2x faster TTFT**.
- Predicted-latency scheduling (NVIDIA GPUs): **40% reduction in TTFT/ITL**.
- Prefill/decode disaggregation (GPT-OSS on B200): **up to 70% higher tokens/sec** — the
  cited condition is a **prefill-heavy workload (20:1 input:output token ratio)**;
  disaggregation's payoff is explicitly phase-imbalance-dependent, not universal.
- Wide expert-parallelism on 16×16 B200s: ~50k tokens/sec cluster throughput (an
  MoE-specific data point, not applicable to this repo's dense Qwen2.5-7B model).

## Implications for vLLM/k8s tuning

- llm-d is a **topology/deployment-architecture choice made before a study starts** —
  the same category `ROADMAP.md` already places NVIDIA Dynamo's Planner/aiconfigurator
  in. It doesn't change what a single vLLM instance's own parameters do; it decides
  *how many* instances exist, in what roles (prefill/decode), and how traffic is routed
  among them.
- **Not relevant to this repo's current single-GPU/single-replica studies** — llm-d's
  entire value proposition (cache-aware routing, disaggregation, pool autoscaling)
  requires multiple replicas/pools to route across in the first place. It becomes
  relevant only if/when a future study scales to backlog #4/H4-H6's multi-replica or
  multi-node territory.
- If a future study does reach that point, llm-d's routing/scheduling policy (EPP
  scoring weights, prefill:decode pool size ratio, KV-offload tier thresholds) would be
  a genuinely new *kind* of tunable surface — not a vLLM parameter, and not expressible
  by the existing vLLM component type at all (see below).

## Which Akamas parameters to explore

N/A for this repo's current scope — no vLLM CLI flag changes; the vLLM engine
underneath llm-d is unchanged. If a future multi-replica study wants to tune llm-d's own
routing/scaling policy, that would need a **new component type** in the optimization
pack (an Inference-Gateway/routing component modeling `InferencePool`/EPP-level
parameters — prefix-cache-affinity weight, load-balance weight, prefill:decode pool
ratio, autoscaling SLO targets) rather than extending the existing vLLM component. Worth
adding to `ROADMAP.md` as a new open question (alongside Q1-Q5) once backlog #4 is
actually scheduled — flagged here for a decision, not added silently.
