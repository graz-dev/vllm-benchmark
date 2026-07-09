<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Unlocking Efficiency in LLM Inference: A Comprehensive Survey of Speculative Decoding

**Source:** Xia, Yang, Dong, Wang, Li, Ge, Liu, Li, Sui — arXiv:2401.07851 (ACL 2024 Findings) — <https://arxiv.org/abs/2401.07851>
**Date distilled:** 2026-07-08

## Problem addressed

An academic survey (not a new method) formalizing the taxonomy of speculative decoding
approaches for LLM inference — how a "drafter" proposes multiple future tokens cheaply
and a "verifier" (the target LLM) confirms them in one parallel forward pass instead of
one sequential pass per token. Complements
`knowledge/notes/2026-07-distributed-inference-advanced-deployment-patterns.md`'s
production-deployment framing of speculative decoding (which method to pick per
workload, constrained-decoding caveats, batch-size interactions) with the underlying
academic taxonomy and a wider comparison table of methods and reported speedups —
distinct source, different methods largely, some overlap (Medusa appears in both).

## Levers / parameters touched

- **Drafting method choice**, formalized into two families:
  - *Independent drafting* — a separate model from the target LLM proposes tokens;
    either fine-tuned specifically as a drafter (SpecDec, Online Speculative,
    DistillSpec) or a "tuning-free" off-the-shelf smaller model from the same model
    family, used unmodified.
  - *Self-drafting* — the target LLM itself proposes tokens, via extra FFN prediction
    heads bolted onto the decoder (Blockwise, **Medusa**), early-exit/layer-skipping
    (PPD, Self-Speculative, SPEED), or mask-predict-style parallel proposal (Parallel
    Decoding, **Lookahead Decoding**, PaSS).
  - Within either family, drafting itself can be parallel (K tokens generated at once)
    or autoregressive (each drafted token conditioned on the previous draft).
- **Verification strategy choice**, three families: greedy (drafted token must exactly
  match the target model's top-1 prediction — deterministic, higher rejection rate),
  nucleus/probabilistic (accept with probability `min(1, q(x)/p(x))` — provably
  preserves the target model's output distribution, not just greedy-equivalent), and
  token-tree verification (multiple candidate continuations merged into a tree, verified
  in parallel via a specialized attention mask — this is the mechanism behind
  tree-based drafters like SpecInfer/Medusa's tree attention).
- **Drafter capacity vs. speedup trade-off**: a named, explicit tension — "scaling up
  the drafter can effectively enhance speculation accuracy, yet it largely reduces the
  drafting efficiency and even the overall speedup" — i.e. a bigger/better drafter
  accepts more tokens per step but costs more time to run itself, and past some point
  that cost erases the benefit.

## Key results

Reported speedups by method (target model + speedup range, from the survey's
comparison table):

| Method | Target model | Speedup |
|---|---|---|
| SpecDec | Transformer-base (65M) | 3.9×–5.1× |
| SpS (speculative sampling) | Chinchilla (70B) | 1.9×–2.5× |
| SpecInfer | LLaMA (30B–65B) | 2.0×–2.4× |
| Medusa | Vicuna (7B–33B) | 1.9×–2.0× |
| Lookahead Decoding | LLaMA-2 (7B–70B) | 1.5×–2.3× |
| REST | Vicuna (7B–13B) | 1.7×–1.8× |
| Parallel Decoding | MBart50 (610M) | 1.0×–1.1× |

- **Larger target models show smaller relative speedups** in this comparison — a
  pattern consistent with (though not identical to — this is target-model size, not
  batch size) the batch-size-saturation theme already logged under H3 in `ROADMAP.md`:
  more headroom being available for a draft model to exploit correlates with getting
  more benefit from speculative decoding.
- **Task-shape strongly affects the achievable speedup**: tasks with high input/output
  similarity give the largest wins — grammatical error correction (SAD) reached
  **9×–12×**, and retrieval-augmented tasks (LLMA) reached **2×–3×** — far above the
  general-purpose 1.5×–5× range in the table above. This is a much sharper, more
  specific version of the "prefix reuse helps" theme already noted from the
  distributed-inference series (cache-aware routing benefits) — here applied to
  speculative decoding specifically: **a RAG-shaped study's workload may see
  dramatically better speculative-decoding speedups than a general chat workload**,
  not just marginally better ones.
- Acceptance rate (tokens accepted per drafting step) is stated as the primary driver
  of speedup, itself a function of drafter capacity, verification strictness (greedy vs.
  nucleus), and how well the drafter's behavior aligns with the target model — no
  formula given, but the mechanism is explicit and consistent with the "acceptance rate
  decay" troubleshooting signal already logged from the blueprints/troubleshooting note.

## Implications for vLLM/k8s tuning

- This survey's drafting/verification taxonomy is a reference for *understanding why*
  the specific methods named in the advanced-deployment-patterns note (EAGLE-3/3.1,
  Medusa, native MTP, n-gram/prompt-lookup) behave differently: EAGLE and Medusa are
  both self-drafting-with-extra-heads approaches (this survey's family), n-gram/
  prompt-lookup is a model-free variant of self-drafting, and native MTP is architecturally
  closest to Medusa's "extra heads trained jointly" idea. Useful for reasoning about a
  *new* speculative-decoding method not yet covered by name in this knowledge base — ask
  "which drafting family and which verification strategy does it use" to predict its
  rough behavior from this survey's taxonomy.
- The **task-shape-dependent speedup magnitude** (9–12× for grammar-correction-like
  tasks, 2–3× for RAG, ~1.5–2.5× general) is a stronger, more specific version of
  guidance already touched on: if a future study's workload is RAG-shaped or has
  high input/output overlap (e.g. structured editing, code completion), speculative
  decoding evaluation should be prioritized higher than for a generic chat benchmark,
  since the achievable win is categorically larger, not just incrementally so.
- The drafter-capacity-vs-speedup trade-off is the same shape as the already-logged
  "speculative decoding gains shrink at large batch size" finding (H3) but along a
  *different* axis (drafter model size vs. concurrency level) — both point to
  speculative decoding needing its own tuning/sizing exercise per workload rather than
  a fixed on/off decision.

## Which Akamas parameters to explore

- No change to the existing pack-request ask: speculative decoding configuration
  (method + draft-model choice) is already logged as missing from the installed vLLM
  pack in `ROADMAP.md`'s debt section, sourced from
  `knowledge/notes/2026-07-distributed-inference-advanced-deployment-patterns.md`. This
  survey doesn't add a new parameter, but does add a concrete reason to prioritize
  *which* method to request pack support for first: if this repo's studies are or will
  be RAG-shaped (per `ROADMAP.md`'s eventual backlog), prioritizing whichever
  speculative-decoding method vLLM supports for high-input/output-overlap workloads
  would have outsized payoff (9–12× territory) vs. a generic chat workload (1.5–2.5×).
- Verification strategy (greedy vs. nucleus) and drafter capacity are sub-configuration
  choices *within* whatever speculative-decoding parameter eventually gets modeled —
  not separate pack-request items, just detail to keep in mind when that parameter's
  domain gets designed (e.g. is verification mode itself a tunable, or fixed per
  method).
