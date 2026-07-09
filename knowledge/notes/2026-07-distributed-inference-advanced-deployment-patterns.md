<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Optimizing Distributed AI Inference: Advanced Deployment Patterns

**Source:** [Red Hat Developer — Optimizing distributed AI inference: Advanced deployment patterns](https://developers.redhat.com/articles/2026/06/24/optimizing-distributed-ai-inference-advanced-deployment-patterns) (part 2 of the 3-part series that started with `knowledge/notes/2026-07-distributed-inference-scaling-dimensions.md`)
**Date distilled:** 2026-07-08

## Problem addressed

Part 1 established the parallelism/topology mental model; this article covers three
concrete operational levers for squeezing more cost/latency/throughput out of a
distributed vLLM deployment once topology is fixed: prefill/decode disaggregation
economics, KV cache tiering/transfer strategy, and speculative decoding method choice.
It frames these as synergistic, not independent — "the real deployment question is how
they work together for a specific traffic shape."

## Levers / parameters touched

- **Prefill/decode disaggregation** (deployment-topology lever, not a single flag):
  decision is traffic-profile-based — compare the ratio of prefill-to-decode GPU-seconds
  in actual traffic against the cost ratio of decode-optimized vs. prefill-optimized
  hardware; pays off only when the cost reduction exceeds the added operational
  complexity (separate pools, KV transfer, routing).
- **KV-transfer connector choice** (vLLM-supported): `NixlConnector` (single-cluster,
  RDMA/NVLink, but its metadata server is a startup single point of failure),
  `LMCacheConnector` (cross-instance sharing, tiered KV + shared prefix index),
  `MooncakeConnector` (cluster-scale shared cache pool, RDMA-native), and
  `MooncakeStoreConnector` (tiered offloading via a distributed master store).
- **KV cache tiering**: L1 HBM → L2 pinned DRAM → L3 NVMe, plus a global prefix index for
  cross-request sharing. Distinct from **KV cache quantization**: FP8 KV cache halves
  memory footprint at "usually acceptable" quality cost; FP4 needs workload-specific
  evaluation before trusting it.
- **Prefix sharing vs. KV cache reuse** — two different routing concerns: prefix sharing
  routes *new* requests with a matching prefix to the worker already holding that warm
  cache; KV cache reuse is session affinity (keep an ongoing conversation pinned to the
  same decode worker). Cache-aware routing (llm-d scheduler) beats round-robin whenever
  prefix reuse is present.
- **Attention/decode kernel choice**: PagedAttention (vLLM's default — better for
  irregular prefixes/varied sequence lengths, scales well under disaggregation) vs.
  RadixAttention (SGLang — better for deep branching/agentic/structured-prompting
  workloads). FlashMLA/ThunderMLA/FlexAttention as decode-kernel accelerators; production
  guidance is to pin identical compiled kernel binaries across all prefill/decode/draft
  replicas (build from source + SBOM, don't pull at runtime).
- **Speculative decoding method** — five families, each a different lever: two-model
  draft-based (EAGLE-3 / EAGLE 3.1), self-speculative (single model drafts+verifies with
  a layer subset), multi-token decoding via extra heads (Medusa), native multi-token
  prediction (MTP, e.g. DeepSeek-V3), and n-gram/prompt-lookup (no draft model at all).
- **Constrained decoding compatibility** — JSON mode / grammar-constrained tool calling
  interacts badly with speculative decoding (see Key results) and needs to be tested per
  workload, not assumed compatible.

## Key results

- Disaggregation cost reduction: **25–40%** on chat- and RAG-shaped traffic (cited
  external results: Splitwise ~20% lower cost at 1.4× throughput; DistServe up to 7.4×
  higher goodput). NOT worth it for single-node deployments (network latency eats the
  gain) or fleets too small to amortize two separate pools.
- Pool sizing example, specific to **Qwen3.5-35B-A3B, 800-token mean prompt, 200-token
  mean output, 5,000 concurrent sessions, H100s**: ~1 H100 per ~30 req/s arrival rate for
  prefill; ~1 H100 per ~150 concurrent sessions for decode; typical chat-workload ratio
  1:3 to 1:5 prefill:decode workers. (Model/workload/hardware-specific — re-derive per
  study, don't reuse these ratios directly.)
- llm-d cache-aware scheduler, **8 pods / 16 H100s, high prefix reuse**: up to **57×**
  faster TTFT in the best case; conservative/typical internal numbers: 25% TTFT
  improvement on default settings, 2–3× tokens/s per GPU, 3–5× cost-per-token reduction
  on chat-shaped traffic with high prefix reuse. The 57× figure is a best case under high
  prefix reuse, not a typical result — don't treat it as expected.
- Speculative decoding acceptance rates (method-dependent, not universal): EAGLE-3 up to
  6× speedup on dense models; EAGLE 3.1 (May 2026) roughly 2× the token-acceptance length
  of EAGLE-3, notably strong on Qwen3.6 long-context; Medusa multi-token heads typically
  0.55–0.70 acceptance at ~50% of EAGLE-3's engineering cost; native MTP (e.g.
  DeepSeek-V3) exceeds 80% acceptance out of the box but can't be retrofitted onto a
  model without retraining.
- Speculative decoding's gains **shrink or invert at large batch sizes** — an
  already-saturated, large-batch decode fleet has less idle forward-pass capacity for the
  draft model to exploit, and can see a net loss; the clearest wins are at low-to-moderate
  concurrency.
- Constrained decoding caveat: under JSON-mode/grammar-constrained tool calling,
  speculative-decoding acceptance "often collapses because the constraint mask
  invalidates speculative tokens" — measure before assuming a win on tool-calling
  traffic.

## Implications for vLLM/k8s tuning

- Like part 1, most of this operates at the **deployment-topology / connector-choice**
  level (which pools exist, which KV-transfer backend, which speculative-decoding
  family) rather than the per-instance parameter values Akamas typically searches over
  in this repo's studies so far. It's a prior for designing a study's System/Components,
  not itself a set of continuous parameters to hand to an optimizer — except where noted
  below.
- The batch-size-dependent shrinkage of speculative-decoding gains is the same
  large-batch story as "Mind the Memory Gap"
  (`knowledge/notes/2026-07-gpu-memory-bound-large-batch-inference.md`) and part 1's
  prefill/decode scheduling-conflict point: several independent sources now say "bigger
  batch/more concurrency doesn't purely help, and can actively hurt a specific
  optimization" — worth treating as a recurring theme across `max_num_seqs` studies here.
- Production hardening notes (dual metadata servers, canary one-pool-at-a-time,
  TTFT+TPOT rollback gates, pinned kernel binaries) are infra/ops practices, not
  Akamas-tunable parameters — relevant to how a disaggregated study's Kubernetes
  manifests are written (`studies/<name>/k8s/`), not to `parametersSelection`.
- Conditions to flag before generalizing: pool-sizing ratios and llm-d scheduler numbers
  are specific to Qwen3.5-35B-A3B / H100 / the traffic shape described; speculative
  decoding acceptance rates are architecture- and workload-specific (long-context vs.
  short conversational vs. code-completion each favor a different method per the
  article's own table). Re-measure per study rather than assuming these numbers transfer.

## Which Akamas parameters to explore

- None of this article's core levers (disaggregation topology, KV-transfer connector
  choice, KV cache tiering, speculative decoding method/config, attention-kernel choice)
  appear in the vLLM component-type parameter list this repo had confirmed installed at
  the time (`gpu_memory_utilization`, `max_num_seqs`, `max_num_batched_tokens`,
  `max_model_len`, `tensor_parallel_size`) — re-check with
  `akamas describe optimization-pack vLLM` or the pack's own repo,
  https://gitlab.com/akamas/optimization-packs/vllm.
  This reinforces the pack-request already logged in `ROADMAP.md`'s debt section for
  part 1's missing parallelism parameters — add these to the same ask rather than a
  separate one:
  - Speculative decoding on/off + method + draft-model reference (vLLM exposes this via
    `--speculative-config`/related CLI flags) — currently no way to let Akamas turn this
    on or pick a method as part of a study.
  - KV cache dtype/quantization (FP8/FP4 KV cache) — a plausible near-term ask since it's
    a single vLLM flag (`--kv-cache-dtype`), unlike the connector/disaggregation topology
    items which are deployment-shape choices, not per-instance parameters.
  - KV-transfer connector selection and disaggregated prefill/decode pool topology are
    deployment-architecture decisions (which Components/Deployments exist in a study's
    System), not parameters within a single vLLM Component — confirm with whoever manages
    packs whether Akamas is even the right tool for topology search vs. a fixed choice
    made before a study starts.
- `vLLM.max_num_seqs` (already modeled) — the speculative-decoding batch-size shrinkage
  finding is another reason a study shouldn't assume "higher is better" for this
  parameter's domain; add to the same body of evidence as H2/H3 in `ROADMAP.md`.
