<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# <Title>

**Source:** <paper / article / blog post / vendor doc title — link it, don't paste it>
**Date distilled:** <YYYY-MM-DD>

## Problem addressed

<What question or bottleneck does this source investigate? 2-4 sentences.>

## Levers / parameters touched

<Which knobs does the source vary or discuss — e.g. batch size, KV cache block size,
scheduling policy, tensor/pipeline parallelism degree, quantization. Be specific.>

## Key results

<The concrete findings — numbers, trends, thresholds. What broke, what scaled, what
plateaued, under which conditions (hardware, model size, workload shape).>

## Implications for vLLM/k8s tuning

<This note is shared across studies, which can each use a different stack (model,
hardware, load generator — see that study's own README). State implications generally,
and flag explicitly if a finding only applies under specific conditions (e.g. a
particular GPU family or model size).>

## Which Akamas parameters to explore

<Map the source's findings onto concrete `vLLM.*` / `GPU.*` / Kubernetes component
parameters. If it suggests a parameter or metric that isn't modeled by any installed
optimization pack, say so explicitly — that's a request for whoever manages optimization
packs (outside this repo), not something to build here.>
