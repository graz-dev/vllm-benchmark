<!--
Template for a study's README. Copied by /new-study into studies/<name>/README.md.
Fill in Objective, Stack & versions, and Parameters tuned when the study is scaffolded;
fill in Results and Conclusions via the study-recap skill once the study finishes.
This file is meant to stand on its own — a reader shouldn't need to check another
study's README or a shared config file to understand what this one did.
-->

# <Study name>

**Status:** TODO | RUNNING | DONE
**Dates:** <start> – <end>

## Objective

<What question this study answers — the goal (metric + direction), any hard
constraints/SLOs, and why it matters. Link back to a ROADMAP.md hypothesis or backlog
entry if this study exists to test one.>

## Stack & versions

<This study is self-contained — record everything needed to understand or reproduce it,
even if it duplicates what another study's README says. Don't assume a reader has seen
another study.>

- **Akamas version:** TODO
- **Optimization pack(s) used:** TODO — name + version for each (e.g. vLLM x.y.z,
  Kubernetes x.y.z). Packs are managed outside this repo; record what was actually
  installed when this study ran, since it can change later.
- **Workload under test:** TODO — e.g. serving image + tag, model, or the specific
  Kubernetes resource being tuned.
- **Cluster / hardware:** TODO — GPU type, node group, region, or a pointer to wherever
  this is documented if shared infra.
- **Load generator:** TODO — tool + version + exact invocation (e.g. GuideLLM vX.Y with
  `--rate-type throughput`, or NVIDIA GenAI-Perf/AIPerf vX.Y). Don't assume another
  study's tool — this is chosen per study.
- **Telemetry:** TODO — provider (e.g. Prometheus) and anything non-default about how
  metrics were collected (scrape interval, window duration).

## Parameters tuned

| Parameter | Domain | Baseline |
|---|---|---|
| TODO | TODO | TODO |

## Results

<Filled in by the study-recap skill once the study finishes.>

- Best configuration found (table: parameter, baseline, best trial).
- Delta vs baseline on the goal metric, and which constraints were binding.
- Top trials table or trend description. Raw data lives in `results/` next to this file
  — link to it rather than pasting large tables here.

## Conclusions

<Filled in by the study-recap skill once the study finishes. What was learned, what
surprised us, and what should happen next. Be explicit about what's generalizable
across studies (candidate for ROADMAP.md) vs specific to this study's exact stack.>
