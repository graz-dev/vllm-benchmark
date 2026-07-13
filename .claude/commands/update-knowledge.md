---
description: Distill a paper, article, blog post, or vendor doc into a knowledge/notes/ entry and update the index — covers parameter tuning, serving tooling/platforms (llm-d, Dynamo, Triton, KServe), inference load-testing methodology, and Kubernetes/GPU infra patterns
---

# update-knowledge

Add one new distilled note to the shared knowledge base. This is **not** paper-only —
articles, blog posts, vendor docs, and conference talks all go through the same
process. The user will hand you a URL, a pasted excerpt/text, or a local file path.

**Scope is broader than vLLM parameter tuning.** This knowledge base covers four kinds
of source, all equally in-scope — don't default to treating "parameter tuning" as the
only lens:

1. **Parameter/config tuning** — what a vLLM/GPU/Kubernetes parameter does and how it
   behaves under load (the original, still-common case).
2. **Serving tooling & platforms** — e.g. llm-d, NVIDIA Dynamo, Triton Inference Server,
   KServe: what they are, how they differ from a bare vLLM Deployment, and when they'd
   change how a study should be set up.
3. **Load-testing tools & methodology for inference** — e.g. GuideLLM, NVIDIA
   GenAI-Perf/AIPerf, vLLM's own `benchmark_serving.py`, k6/Locust adaptations: how each
   measures TTFT/ITL, open-loop vs. closed-loop load generation, synthetic vs. trace
   replay — this shapes how a study's `windowing`/load-generator choice should be judged,
   not just which parameters it tunes.
4. **Kubernetes/infra patterns for GPU/AI workloads** — device plugins, MIG/time-slicing/
   MPS, Dynamic Resource Allocation (DRA), GPU-aware autoscaling (KEDA/Karpenter/HPA),
   node pool/taint conventions, multi-tenancy and priority/preemption for GPU pods — the
   cluster-level decisions a study's environment is built on, distinct from what Akamas
   tunes inside it.

A source doesn't need to map onto a tunable Akamas parameter to be worth a note — a
tooling or infra pattern that changes how a *future study* should be scoped or set up is
just as valuable as a parameter finding. Say so explicitly in "Which Akamas parameters to
explore" when a source is this kind (e.g. "N/A — this is a platform/infra choice made
before a study starts; see `ROADMAP.md`'s tooling questions (section A, Q1-Q5) or
backlog" — don't force a source into the parameter-shaped mold it doesn't fit.

1. **Get the source content.**
   - URL: fetch it (WebFetch). If it's paywalled, JS-rendered, or otherwise unfetchable,
     ask the user to paste the relevant text instead of guessing at its content.
   - Pasted text: use it directly.
   - Local file (e.g. a PDF): read it. If it's worth keeping a durable local copy (a
     paper you'll reference repeatedly), save it under `knowledge/sources/`; for an
     ordinary web article, don't bother mirroring the whole page — the note's `Source:`
     link is enough.
2. **Check `knowledge/README.md`'s index first** — if this source (or a near-duplicate)
   already has a note, tell the user and ask whether to update the existing note instead
   of creating a new one.
3. **Copy `knowledge/notes/_TEMPLATE.md`** to `knowledge/notes/<slug>.md` — kebab-case,
   optionally date-prefixed (e.g. `2026-07-continuous-batching.md`).
4. **Fill in every section** by distilling, not summarizing-everything or pasting:
   - `Source` + `Date distilled`
   - `Problem addressed` — 2-4 sentences
   - `Levers / parameters touched` — the specific knobs the source discusses; for a
     tooling/infra/load-testing source without tunable "knobs" in the parameter sense,
     use this field for the equivalent design choice instead (e.g. which load-testing
     tool, which autoscaler, which GPU-sharing mechanism, which disaggregation topology)
   - `Key results` — concrete numbers/trends/thresholds, with the conditions they held
     under (hardware, model size, workload shape) — a finding without its conditions is
     not usable later
   - `Implications for vLLM/k8s tuning` — generalize carefully; this note is shared
     across studies that may use different stacks, so flag anything condition-specific
   - `Which Akamas parameters to explore` — map findings to concrete `vLLM.*` / `GPU.*` /
     Kubernetes component parameters. If the source implies a parameter/metric no
     installed optimization pack models, say so explicitly — check the pack's own repo
     (e.g. <https://gitlab.com/akamas/optimization-packs/vllm>) or run `akamas describe
     optimization-pack <name>`; that's a request for whoever manages packs (see the
     `akamas-optimization-pack` plugin), not something to build here.
   If a section genuinely doesn't apply, say so explicitly rather than leaving
   placeholder-shaped filler text.
5. **Add a row to `knowledge/README.md`'s index table**: note name/link, problem
   (one line), relevant Akamas parameters.
6. If the note surfaces something that should become a `ROADMAP.md` hypothesis, backlog
   idea, or open tooling/infra question (section A's Q-numbered items are exactly this
   shape) say so and ask before adding it — don't edit `ROADMAP.md` silently from this
   command.
7. Report back with the note's one-line takeaway — not the full distilled text.
