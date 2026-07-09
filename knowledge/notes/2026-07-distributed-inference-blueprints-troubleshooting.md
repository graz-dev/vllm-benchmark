<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Deploying Distributed AI Inference: Blueprints and Troubleshooting

**Source:** [Red Hat Developer — Deploying distributed AI inference: Blueprints and troubleshooting](https://developers.redhat.com/articles/2026/06/26/deploying-distributed-ai-inference-blueprints-troubleshooting) (part 3, last of the 3-part series started by
`knowledge/notes/2026-07-distributed-inference-scaling-dimensions.md` and
`knowledge/notes/2026-07-distributed-inference-advanced-deployment-patterns.md`)
**Date distilled:** 2026-07-08

## Problem addressed

Parts 1–2 gave the parallelism/topology mental model and the individual optimization
levers (disaggregation, KV-cache strategy, speculative decoding); this article maps them
onto six concrete deployment blueprints by workload shape, gives a phased "when to add
which lever" scaling roadmap, and provides a troubleshooting playbook (symptom → likely
cause → fix) for running distributed vLLM in production. It also adds two levers not
covered in parts 1–2: chunked prefill and model cascading.

## Levers / parameters touched

- **Chunked prefill ("stall-free scheduling")**: splits a long prompt's prefill into
  chunks interleaved with queued decode steps, so a long prompt doesn't block short ones
  behind it — a scheduling-policy lever, not a topology one.
- **Model cascading**: routes simple queries to the smallest capable model, escalating to
  a larger one only on low-confidence signals or policy — a routing-layer lever above any
  single vLLM instance.
- **SLO-aware admission control**: tiered (e.g. gold/silver/bronze) request admission at
  the gateway; rejects requests likely to blow a token-limit/timeout budget before they
  consume GPU cycles, rather than after.
- **Continuous/batch scheduling + scale-to-zero**: for latency-tolerant batch workloads,
  reordering requests to keep batches full, plus KServe+KEDA scaling to zero between
  waves, plus spot/preemptible capacity.
- Reuses parts 1–2's levers in context: prefill/decode disaggregation, TP/PCP/DP/EP,
  KV-cache offload tiering (LMCache), prefix caching, speculative decoding (EAGLE 3.1).
- **Troubleshooting signals** (operational, not tunable, but define what to watch when a
  study's results look off): TTFT, TPOT, KV-cache utilization, per-worker/per-request
  queue depth, NIXL queue depth (disaggregated fleets), draft-head acceptance rate
  (speculative decoding).

## Key results

- **Six deployment blueprints**, each with a distinct cost driver and topology — useful
  as a checklist for "which blueprint does this study's target workload resemble":
  1. **High-concurrency chat** (thousands of users, short prompts, TPOT-bound) →
     disaggregated prefill/decode, decode pool needs LMCache DRAM/NVMe offload +
     cache-aware routing + EAGLE 3.1 + chunked prefill; decode-dominated cost.
  2. **Long-context RAG/code** (32k–256k prompts, TTFT-bound) → TP within node + PCP
     across GPUs, prefix caching, chunked prefill; prefill-dominated cost, prefix-cache
     hit rate directly drives $/Mtoken.
  3. **High-throughput batch** (latency-tolerant, $/token-bound) → heavy DP + continuous
     scheduling + aggressive quantization + scale-to-zero + spot capacity;
     disaggregation gives **no benefit** here (a useful negative case).
  4. **Multi-tenant "AI-grid"** (multiple models/tenants, bursty, varied SLOs) → per-model
     llm-d InferencePools + shared LMCache fabric + cascading + SLO-tiered admission;
     cost is non-linear — a poorly designed version becomes "a fragmented zoo of
     single-tenant pools each running at low utilization."
  5. **Hybrid sovereign-to-cloud-burst** → single control plane spanning on-prem + cloud,
     congestion/topology-aware routing; efficiency hinges on the burst cluster staying
     truly idle between peaks and warming up fast (predictive prewarming, pinned
     images/kernels, pre-warmed CUDA graphs/KV pools) rather than on standing capacity.
  6. **Edge on workstation-class GPU** (1–50 users, single site) → single vLLM instance,
     **no** disaggregation ("prefill-decode transfer hop costs more than it saves below
     ~100 concurrent sessions"). Concrete capacity math for Qwen3.6-27B (hybrid Gated
     DeltaNet — only 16/64 layers keep per-token KV cache, 4 KV heads at head_dim 256 ⇒
     ~64KB/token FP16, ~32KB/token FP8) on a 96GB card: FP8 weights ~27GB + ~4GB working
     memory ⇒ ~65GB left for KV cache (~2M cumulative tokens) ⇒ roughly 50 sessions at
     32k context, 15 at 128k, or 4 at 512k (FP4 KV). Same card: Qwen3.5-35B-A3B FP8 leaves
     ~55GB for KV cache; Qwen3.5-397B-A17B **cannot fit a single card at any production
     precision** regardless of quantization.
- **Phased scaling roadmap** (the most directly reusable part for how this repo sequences
  studies):
  1. Baseline: single node, single vLLM instance, ≥1 week of production-traffic TTFT/TPOT
     as the reference everything else is compared against.
  2. Add smart routing (llm-d) when a single-node fleet stops scaling linearly — concrete
     trigger: **a second replica behind round-robin produces <1.8× the throughput of one
     node** (round-robin misses cache hits that cache-aware routing would catch).
  3. Disaggregate + add speculative decoding only once *measured* prefill/decode
     imbalance justifies the KV-transfer cost — premature disaggregation costs more than
     it saves; add spec-decoding after concurrency stabilizes (its gains are largest at
     low concurrency, shrink under saturation — consistent with part 2's finding).
  4. Move to the multi-tenant "AI-grid" blueprint only once actually serving multiple
     model classes to multiple tenants — cascading/SLO-classes/shared-cache/GitOps are
     "highly effective at scale, unnecessary overhead for smaller setups."
- **Troubleshooting playbook** (symptom → cause → fix), directly reusable when a study's
  benchmark run looks anomalous:
  - Sudden TPOT rise + climbing KV-cache utilization → fragmentation/aggressive
    preemption → adjust preemption threshold, confirm chunked prefill is enabled.
  - MoE run with degraded throughput + high queue depth on 1–2 experts → hot-expert
    imbalance → enable EPLB or replicate the hot expert.
  - Disaggregated fleet: stable TTFT but TPOT spikes on prompt arrival → rising NIXL
    queue depth blocking decode during KV transfer → check RDMA driver health and that
    the NIXL metadata server isn't a SPOF.
  - Speculative decoding active but throughput flat/down → draft-head acceptance rate has
    decayed (workload/model drift) → inspect per-request acceptance metrics.
  - Process discipline: canary config changes, watch TTFT **and** TPOT together, never
    change two scheduler parameters at once (directly relevant to how an Akamas study
    should isolate parameter effects too).

## Implications for vLLM/k8s tuning

- The blueprint table is a useful **pre-study checklist**: before designing a study's
  System, identify which of the six workload shapes it resembles and whether
  disaggregation/cascading/multi-tenancy even apply — most studies in this repo so far
  (single vLLM Component/topology) map to blueprint 1, 2, or 6 depending on prompt
  length and concurrency, not 3–5.
- The **<1.8× throughput trigger for a second replica** is a concrete, testable signal
  this repo could actually measure in a future replica-count study (ties to H4/backlog
  #4) — it's phrased as a routing-strategy diagnostic (round-robin vs. cache-aware), not
  a tuning target, but it's a genuinely falsifiable number rather than vague guidance.
  Its exact value is llm-d/routing-specific — verify it holds before using it as a
  go/no-go threshold in this repo's own infra.
- The troubleshooting playbook's "watch TTFT and TPOT together, never change two
  scheduler parameters simultaneously" is directly applicable to how any Akamas study
  here should reason about noisy or unexpected experiment results — a TPOT spike with
  flat TTFT and rising KV utilization is diagnosable *without* needing NIXL/disaggregation
  at all (it's a preemption/chunked-prefill signal), useful even for this repo's
  currently non-disaggregated studies.
- The edge blueprint's capacity math (bytes/token from KV-head count × head_dim, not just
  raw model size) is a generalizable way to *predict* a model's max concurrent-session
  ceiling on a given GPU before running a study — useful for sanity-checking a study's
  `max_num_seqs` domain upper bound against actual VRAM, rather than guessing.
- Everything blueprint-4/5-specific (llm-d InferencePools, Envoy AI Gateway, GitOps,
  KEDA, hybrid sovereign-cloud) assumes infrastructure this repo doesn't currently
  provision (see `ROADMAP.md` debt: cluster/environment provisioning is out of scope
  here) — treat as future-relevant, not actionable today.

## Which Akamas parameters to explore

- No new per-instance vLLM parameters beyond what parts 1–2 already flagged as missing
  (speculative decoding config, KV cache dtype, disaggregation/connector topology — see
  `ROADMAP.md`'s pack-request debt item). Chunked prefill is a vLLM scheduling flag
  (`--enable-chunked-prefill` / related batch-token sizing) that overlaps with the
  already-modeled `vLLM.max_num_batched_tokens` — worth checking with
  `akamas describe optimization-pack vLLM` whether chunked-prefill toggling is exposed
  as its own parameter or only implicit in batching settings.
- **Preemption threshold / KV-cache preemption policy** is called out here as a concrete
  troubleshooting lever (fragmentation → adjust preemption threshold) that wasn't listed
  in this repo's tracked vLLM parameter summary at the time — worth confirming with
  `akamas describe optimization-pack vLLM` whether it's
  actually exposed; if not, add it to the same pack-request ask as the other missing
  items.
- Model cascading, SLO-aware admission control, and multi-tenant routing are
  gateway/routing-layer concerns above a single vLLM Component — not something a
  single-Component Akamas study's `parametersSelection` would model; relevant only if a
  future study's System spans multiple Components/tenants (blueprint 4 territory).
