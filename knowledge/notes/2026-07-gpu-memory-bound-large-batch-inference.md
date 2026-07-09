# Mind the Memory Gap: Unveiling GPU Bottlenecks in Large-Batch LLM Inference

**Source:** Recasens, Agulló, et al. — arXiv:2503.08311 — <https://arxiv.org/abs/2503.08311>
(code: <https://github.com/FerranAgulloLopez/vLLMBatchingMemoryGap>, a vLLM fork)
**Date distilled:** 2026-07-08

## Problem addressed

Conventional wisdom says LLM inference throughput plateaus at large batch sizes because
the workload shifts from memory-bound to compute-bound. The paper does a GPU-level
(kernel/cycle) analysis on vLLM and finds this explanation is wrong for the cases they
tested: throughput plateaus because DRAM bandwidth saturates, not because compute does —
most GPU compute capability stays idle even at the "plateau." They then build a
**Batching Configuration Advisor (BCA)** that picks a smaller KV-cache allocation
(and therefore effective batch size) that reaches near-peak throughput while freeing a
large fraction of GPU memory, and use the freed memory to run additional model replicas
on the same GPU.

## Levers / parameters touched

- Batch size / max concurrent sequences (maps to vLLM's `max_num_seqs`)
- KV cache memory allocation (maps to vLLM's `gpu_memory_utilization`, which sets the
  memory pool the KV cache is carved from)
- Model replication — running multiple vLLM instances on the same GPU (a
  deployment/replica-count question, not a vLLM-internal parameter)

## Key results

Tested on a single NVIDIA H100 (64GB), models OPT-1.3B, OPT-2.7B, Llama-2-7B,
Llama-2-13B, vLLM with xFormers attention, ShareGPT-derived requests (avg 161 input /
338 output tokens):

- OPT-2.7B: 225 tok/s at batch 1 → ~7,607 tok/s at batch 256 — only a **33.8x** gain for
  a 256x batch increase (not linear, as expected), and the plateau starts around
  **batch size ~32** for the smaller models tested.
- Decode dominates: ~95% of total execution time is the decode phase, not prefill.
- At the plateau, attention kernels stall >50% of cycles waiting on memory access
  (xFormers hit >80% idle cycles at max batch); L1 cache hit rate ~12%, L2 ~2% — i.e. the
  bottleneck is DRAM bandwidth, not SM occupancy.
- KV cache is over-provisioned relative to what's needed for near-peak throughput:
  OPT-1.3B reaches near-max throughput using only ~40% of its KV cache; BCA pushes this
  further, hitting **83.13%** of max throughput using only **16.32%** of KV cache.
- Memory freed by BCA: OPT-1.3B 63.23%, OPT-2.7B 45.05%, Llama-2-7B 10.51% (savings drop
  sharply as model size grows — less slack for a 7B+ model on this GPU).
- Using freed memory for extra replicas on the same GPU: OPT-1.3B +33.7% throughput with
  4 replicas; OPT-2.7B +7.49–12.78% with 2 replicas; ~78% CPU-overhead reduction with 2
  replicas (fewer/larger batches per replica means less per-request CPU-side work).

## Implications for vLLM/k8s tuning

Conditions to flag explicitly before generalizing: single H100 64GB, xFormers attention
backend, small-to-mid models (1.3B–13B) — not yet verified on the A10G-class or larger
GPUs, or on 7B+ models where the memory-saving effect was already shrinking (10.51% for
Llama-2-7B). The core mechanism (DRAM bandwidth saturation, not compute, driving the
batch-size plateau) is architectural and should generalize; the *exact* batch size where
it kicks in and the *magnitude* of memory to free up are model+GPU+attention-backend
specific and should be re-measured per study, not assumed from this paper.

This is a strong prior for `ROADMAP.md`'s **H2** (`gpu_memory_utilization` diminishing
returns) and **H3** (`max_num_seqs` saturates before its domain's upper bound) — this
paper gives a mechanism (DRAM bandwidth, not KV-cache exhaustion) for why both should
plateau, and suggests the plateau point is lower than intuition suggests (~32 for small
models here). It also directly motivates **H4** (co-tuning Kubernetes alongside vLLM):
the paper's actual proposed win isn't a better single-instance config, it's using the
memory *freed* by a smaller-than-default config to run more replicas — i.e. a
Kubernetes-level replica-count/HPA decision made jointly with vLLM's batching
parameters, exactly the kind of joint optimization H4 asks about.

## Which Akamas parameters to explore

- `vLLM.gpu_memory_utilization` and `vLLM.max_num_seqs` — this paper suggests a joint
  optimum exists well below max values (contrary to "higher is strictly better until
  OOM"); a study's `parametersSelection` domain shouldn't assume the top of the range is
  ever optimal for throughput-per-GPU (it may still be optimal for single-replica
  latency, which is a different goal).
- **Replica count is not currently modeled** in this repo's `system.yaml` reference
  example. If we want to test something like BCA's actual proposal (free memory → add
  replicas), a study needs a Kubernetes-pack parameter for Deployment `replicas` (or an
  HPA min/max) as a tunable alongside the vLLM component — confirm this parameter exists
  in whatever Kubernetes optimization pack is installed
  (`akamas describe optimization-pack Kubernetes`); if it doesn't, that's a request for
  whoever manages packs, not something to build in a study folder.
