<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Designing Distributed AI Inference: Core Concepts and Scaling Dimensions

**Source:** [Red Hat Developer — Designing distributed AI inference: Core concepts and scaling dimensions](https://developers.redhat.com/articles/2026/06/22/designing-distributed-ai-inference-core-concepts-and-scaling-dimensions) (part 1 of a 3-part series)
**Date distilled:** 2026-07-08

## Problem addressed

Picking a serving engine (e.g. vLLM) doesn't determine how a service scales or balances
cost against performance — that's decided by runtime layout: how prefill/decode work is
distributed, how many GPUs are used, and along which dimension (tensor, pipeline, expert,
data, context). The article gives a mental model for mapping workload shape (concurrency,
prompt/context length, model architecture) onto a parallelism configuration, before any
concrete deployment tuning.

## Levers / parameters touched

- **Prefill vs. decode disaggregation**: homogeneous pool (same workers do both phases,
  simpler but causes scheduling conflicts — large prefill batches delay queued decode
  steps, raising TPOT) vs. disaggregated pool (separate prefill/decode workers, avoids
  arbitration but requires KV cache transfer between them).
- **Tensor parallelism (TP)**: shards weight matrices across GPUs, per-layer all-reduce;
  latency-sensitive, needs NVLink/NVSwitch to scale across nodes well.
- **Pipeline parallelism (PP)**: shards by layer range, point-to-point activation
  passing; tolerates Ethernet-class inter-node fabric far better than TP; bubbles hidden
  via micro-batching.
- **Expert parallelism (EP)**: distributes MoE experts across GPUs; traffic is bursty/
  asymmetric (hot experts become tail-latency anchors); Expert Parallel Load Balancing
  (EPLB) can rebalance but adds overhead that may not pay off under stable routing
  patterns.
- **Data parallelism (DP)**: full model replicas behind a load balancer; linear
  throughput scaling, simplest lever, but exposed to API-server bottlenecks and ignores
  KV-cache-hit-rate/MoE-sync costs if stacked blindly.
- **Context parallelism (CP)**, split by phase:
  - *Prefill CP (PCP)*: shards the sequence dimension across additional GPUs to cut
    TTFT on long prompts (attention cost is quadratic in prompt length); expands world
    size (device count = TP × PCP), separate comm domain.
  - *Decode CP (DCP)*: shards the KV cache along the sequence dimension **within the
    existing TP group** — no extra GPUs. Removes KV cache duplication that occurs under
    plain TP when KV heads < TP ranks (relevant to architectures with few KV heads, e.g.
    Qwen3.5), freeing HBM for larger decode batches → higher throughput.
- **Quantization** as a first lever before scaling (recommended order: quantize → set
  minimum TP to fit with KV headroom → scale via DP; for MoE, quantize → try EP+DP on
  one node → reach for PP only if weights still don't fit).
- **Speculative decoding** (EAGLE 3.1, mentioned as a maturing lever) and **KV cache
  transfer/reuse/offload** systems (NIXL, LMCache, Mooncake) as adjacent tuning surfaces.

## Key results

- Six KPIs trade against each other by construction: TTFT, TPOT, throughput, GPU
  utilization, KV cache hit rate, cost efficiency — no single config wins on all six.
- Disaggregation threshold is not model size or token count but *measured* phase
  imbalance where KV-transfer overhead is smaller than the savings from right-sizing
  prefill/decode pools separately.
- Concrete example configs (all FP8 unless noted; H100 GPUs):
  - Qwen3.6-27B (dense), 1×H100 FP8 → TP=1 (~27GB weights fits one GPU).
  - Same model, 8×H100 FP8 → DP=8, TP=1/replica (pure replication once weights fit one GPU).
  - Qwen3.5-35B-A3B (MoE), 8×H100 FP8 → DP=8, EP=8.
  - Same MoE model, 8×H100 **BF16** (no quantization, ~70GB weights) → TP=2, DP=4, EP=8
    (TP needed just to fit before DP/EP kick in).
  - Qwen3.5-397B-A17B (MoE), 16×H100 across 2 nodes, FP8 → PP=2, EP=8 (~397GB weights
    force cross-node layer split via PP, with EP sharding experts within each node).
  - Any Qwen3.5 with ≥128k context: add `--decode-context-parallel-size 2` for decode
    throughput (no extra GPUs) or `--prefill-context-parallel-size 2` for TTFT (adds
    GPUs, world size = TP × PCP). Qwen3.5's native context is 262k tokens, making CP
    "unavoidable for any serious long-context deployment" at that model family.
- These numbers are architecture/precision-specific (FP8 vs BF16 changes whether TP is
  needed at all just to fit weights) — don't generalize the exact TP/DP/EP/PP values to
  a different model or GPU without redoing the "does it fit" math.

## Implications for vLLM/k8s tuning

- This is a **capacity-planning/topology** framework, not a per-request tuning knob
  space — it operates one level above what Akamas typically optimizes (single-instance
  parameter values). It matters most when deciding a study's System topology (how many
  GPUs/replicas, TP degree) *before* running an Akamas optimization on top of that fixed
  topology.
- Where it does map onto per-instance tuning our studies already do: `max_num_seqs` /
  `max_num_batched_tokens` (Akamas territory) interact with the disaggregation decision
  — a homogeneous pool's prefill/decode scheduling conflict is exactly the batching
  trade-off these two parameters already control; findings here explain *why* large
  batch sizes can raise TPOT even when GPU compute isn't saturated, complementing "Mind
  the Memory Gap" (`knowledge/notes/2026-07-gpu-memory-bound-large-batch-inference.md`)'s
  DRAM-bandwidth explanation for the same symptom (both point at "big batches can hurt
  tail latency for reasons other than raw compute capacity").
- `tensor_parallel_size` is the one parallelism dimension already in the installed vLLM
  pack (confirm with `akamas describe optimization-pack vLLM`) — this
  article's guidance ("quantize first, minimum TP for fit + KV headroom, then scale via
  DP") is directly usable as a *prior* on where to set that parameter's domain/default,
  not just a random Akamas search over the full TP range.
- Everything condition-specific here (Qwen3.5/3.6 numbers, H100 hardware, FP8 vs BF16
  fit thresholds) should NOT be assumed to hold for whatever model/GPU a given study
  actually uses — re-derive the "does it fit" arithmetic per study's own stack (see
  CLAUDE.md rule 6).

## Which Akamas parameters to explore

- `vLLM.tensor_parallel_size` (already modeled) — this article gives a principled
  starting domain: minimum value that fits the model + KV cache headroom in FP8/BF16 on
  the study's actual GPU, rather than sweeping arbitrarily.
- `vLLM.max_num_seqs` / `vLLM.max_num_batched_tokens` (already modeled) — reframe as the
  practical lever for the prefill/decode scheduling conflict described here, when a
  study is running a homogeneous (non-disaggregated) pool, which is the only topology a
  single-instance Akamas vLLM Component currently represents.
- **Not modeled by any installed pack (flag for whoever manages packs, not built here)**:
  - Pipeline parallelism (`pipeline_parallel_size`), expert parallelism (`EP`/MoE expert
    count and EPLB toggles), decode/prefill context parallelism
    (`--decode-context-parallel-size`, `--prefill-context-parallel-size`), and
    prefill/decode disaggregation topology (separate prefill vs. decode
    Deployments/StatefulSets with KV-transfer routing) are all vLLM CLI flags this
    article discusses but weren't part of the vLLM component-type parameter list this
    repo had confirmed installed at the time. Confirm with
    `akamas describe optimization-pack vLLM` whether the installed pack has since added
    any of these — if not, they're candidates to request from the pack owner before any
    study can optimize multi-node/MoE topologies rather than just single-instance
    parameters.
  - A Kubernetes-level "replica count / HPA policy" parameter, already flagged as
    missing by "Mind the Memory Gap"
    (`knowledge/notes/2026-07-gpu-memory-bound-large-batch-inference.md`), is reinforced
    here as the DP lever this article describes ("full model replicas behind a load
    balancer") — still not modeled.
