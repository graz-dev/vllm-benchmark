<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Unlock Massive Token Throughput with GPU Fractioning in NVIDIA Run:ai

**Source:** [NVIDIA Developer Blog — Unlock massive token throughput with GPU fractioning in NVIDIA Run:ai](https://developer.nvidia.com/blog/unlock-massive-token-throughput-with-gpu-fractioning-in-nvidia-runai/)
**Date distilled:** 2026-07-08

## Problem addressed

Whole-GPU allocation for LLM inference wastes capacity when a model doesn't need a full
GPU's memory/compute — the article cites a 14B model using only ~35% of an H100 NVL's
80GB. NVIDIA Run:ai's GPU fractioning lets multiple inference replicas (same model or
different models) share a physical GPU with memory isolation and fair compute-cycle
distribution, scheduled by Run:ai rather than manual placement. This is a vendor
benchmark report (NVIDIA + Run:ai), the most quantitatively detailed source yet in this
knowledge base for the "multiple replicas per GPU" mechanism this repo's H4/backlog #4
has been building toward from a purely vLLM-parameter angle (via
"Mind the Memory Gap") — here it's the infrastructure/scheduler-level version of the
same idea.

## Levers / parameters touched

- **GPU fraction per replica** (Run:ai-specific, not MIG/time-slicing/MPS): users
  specify memory requirement directly rather than picking a preset fraction size; the
  scheduler enforces memory isolation at runtime while distributing compute cycles
  fairly among co-located processes.
- **Guaranteed minimum (Request) + burstable upper bound (Limit)** — analogous in
  concept to Kubernetes CPU/memory requests/limits, but for GPU fraction: a replica gets
  at least its Request and can burst up to its Limit when spare capacity exists.
- **Replica count / autoscaling** (1→16 replicas tested) — Run:ai's scheduler handles
  this on top of fractioning, not a separate mechanism.
- **Multi-model co-location** on shared GPUs — different models at different fraction
  sizes on the same physical GPU simultaneously (e.g. 0.5 + 0.25 + 0.125 GPU).
- Benchmarked with **GenAI-Perf** (ties to `ROADMAP.md` Q2's load-generator evaluation)
  simulating concurrent users (CCU), measuring TTFT, output token throughput, GPU
  utilization.

## Key results

All results on **Llama 3.1 8B Instruct (~16GB), Phi-4-Mini (3.8B, ~8GB), Qwen3-14B
(14B, ~28GB, ~35% of an H100 NVL 80GB), Qwen-Embeddings-0.6B (~1.5GB)**, on-prem **64×
H100 NVL (80GB)** or cloud **32× HGX B200** (Nebius AI Cloud):

- **Llama 3.1 8B at 0.5 GPU allocation, 64×H100 NVL**: 8,768 concurrent users (86% of
  the 10,200 CCU a full-GPU allocation reaches), TTFT under 1,000ms for every user,
  152,694 tokens/s output throughput (77% of full-GPU's 198,680 tokens/s) — i.e. a
  half-size fraction delivers most (not all) of a full GPU's capacity, meaning **two
  0.5-GPU replicas together can exceed a single full-GPU replica's throughput** (2×
  152,694 = 305,388 > 198,680), the same "smaller allocation × more replicas beats one
  big allocation" pattern "Mind the Memory Gap" found from the vLLM-memory-tuning side.
  Scaling from 1 to 64 GPUs was linear.
- **Phi-4-Mini at 0.25 GPU, 32×HGX B200**: ~12,200 concurrent users vs. 7,100 for a
  full-GPU allocation — **72% more concurrent users** from a smaller model at a smaller
  fraction; ~450K tokens/s combined throughput with P95 TTFT under 300ms.
- **Multi-model co-location, 32×HGX B200**: two models each at 0.5 GPU nearly doubled
  total concurrent users (17,792 vs. 9,934 for one model at full GPU). A **mixed
  workload** (0.5 Llama + 0.25 Phi + 0.125 Qwen simultaneously) reached ~3× the
  concurrent-user capacity of a Llama-only full-GPU deployment at the same cluster scale
  (9,190 vs. 3,000 CCU), and 354,312 vs. 200,979 tokens/s combined throughput — with
  "no cross-model interference" reported.
- **Scheduler overhead**: Run:ai's fractioned scheduling showed **no measurable
  performance penalty** vs. native Kubernetes scheduling — at 64 GPUs, Run:ai actually
  reached slightly higher CCU (10,200) than native K8s (9,934), though this delta is
  small enough to read as "no overhead" rather than a genuine Run:ai advantage.
- **Autoscaling**: replicas scaled smoothly 1→16 with no TTFT spikes, stable GPU
  utilization during pod warm-up, negligible HTTP error rates.

## Implications for vLLM/k8s tuning

- This is the most concrete quantitative evidence yet for **H4/backlog #4's core
  mechanism**: smaller-than-full GPU allocations, multiplied across more replicas,
  can exceed one maximally-sized replica's throughput on the same total hardware — here
  demonstrated at the infrastructure/scheduler level (GPU fractioning) rather than the
  vLLM-parameter level ("Mind the Memory Gap"'s under-allocating `gpu_memory_utilization`).
  These are two different mechanisms reaching a structurally similar conclusion:
  "Mind the Memory Gap" operates *within* a single vLLM process's own memory allocation
  (still one GPU, one vLLM instance, freed memory used for co-located replicas of the
  same process), while Run:ai fractioning operates at the *scheduler* level (multiple
  independent Pods/containers, each with a hard-isolated GPU-memory slice) — a study
  testing this mechanism needs to be clear about which layer it's actually exercising.
- **Vendor/infrastructure dependency, not a vLLM or Akamas concern**: GPU fractioning
  this specific way is a NVIDIA Run:ai capability — it requires that scheduler to be
  installed on the target Kubernetes cluster. This repo's current cluster/environment
  provisioning is out of scope per `ROADMAP.md`'s debt list; before treating this as
  directly actionable, confirm whether the target cluster runs Run:ai, or a different
  GPU-sharing mechanism (MIG, time-slicing, MPS) with potentially different isolation/
  overhead characteristics that these specific numbers wouldn't transfer to.
- Smaller models benefit disproportionately from fractioning (Phi-4-Mini's 72% CCU gain
  at 0.25 GPU vs. Llama-8B's 86%-of-full-GPU-capacity at 0.5 GPU) — consistent with
  "Mind the Memory Gap"'s finding that memory-freeing benefit shrinks as model size
  grows (that paper: 63% memory freed for a 1.3B model vs. 10.5% for a 7B model). A
  third independent confirmation that this whole class of mechanism (whether via vLLM
  memory tuning or GPU fractioning) matters most for smaller models, less for
  large ones.
- The **Request/Limit split for GPU fraction** is conceptually the GPU analogue of
  Kubernetes container CPU/memory requests/limits already discussed under H4 — if a
  study's cluster has GPU-fractioning capability, this is another dimension (fraction
  size, not just replica count) that a Kubernetes-level parameter would need to
  represent.

## Which Akamas parameters to explore

- No vLLM parameter changes — this is entirely an infrastructure/scheduler-level
  mechanism. It reinforces the same gap already logged in `ROADMAP.md` under H4/backlog
  #4 (a Kubernetes-pack replica-count/HPA parameter, still not confirmed as modeled) —
  but adds a **new dimension to that gap**: if GPU fractioning is available on the
  target cluster, the missing parameter isn't just "how many replicas" but also "GPU
  fraction (Request/Limit) per replica." Whoever manages packs would need a GPU-sharing-
  aware component type (Run:ai-specific or MIG/time-slicing-specific, not currently
  covered by the generic Kubernetes/GPU packs — confirm with
  `akamas describe optimization-pack GPU`/`Kubernetes`) — flag as an addition
  to the existing pack-request ask, conditional on confirming the target cluster
  actually has such a scheduler installed.
