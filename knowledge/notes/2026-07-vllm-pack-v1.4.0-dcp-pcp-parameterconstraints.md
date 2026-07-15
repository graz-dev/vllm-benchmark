<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# vLLM Optimization Pack v1.4.0 — New Parameters and Reusable `parameterConstraints`

**Source:** direct pack-authoring work on
https://gitlab.com/akamas/optimization-packs/vllm, branch
`feature/attention-backend-and-block-size-categorical`, commit `2121136`
(this repo's own `.claude` tooling, not an external source — recorded here per this
repo's convention of routing anything reusable-across-studies through a knowledge note
before it reaches a study manifest).
**Date distilled:** 2026-07-14

## Problem addressed

This repo's own pack audit (2026-07-14, see the "Pack request" debt item history in
`ROADMAP.md`) found several previously-tracked "missing parameter" asks were stale or
unverifiable, and one existing parameter (`block_size`) could be modeled more
efficiently. This note distills what was actually implemented directly on the pack's
open branch, and — the reusable part — gives every study author the exact
`parameterConstraints` snippets needed to use the two new parameters safely, since
Akamas packs have no pack-level cross-parameter constraint mechanism of their own.

## Levers / parameters touched

`block_size` (domain-type change: categorical → ordinal, same values), new parameters
`decode_context_parallel_size` and `prefill_context_parallel_size` (vLLM's DCP/PCP —
decode/prefill context parallelism), plus a definitive resolution (present/absent,
verified against vLLM `v0.22.0` source) for several previously-open pack-request items.

## Key results

- **`block_size`: categorical → ordinal.** Same 8 values
  (`"16","32","48","64","80","96","112","128"`), same default `"16"`. Categorical
  one-hot-encodes values with no notion of order; ordinal preserves it, letting the
  optimizer exploit adjacency (e.g. that `32` sits between `16` and `64`) instead of
  treating all 8 as unrelated buckets — an optimizer-**efficiency** improvement, not a
  correctness fix (the categorical version was already correct). **Caveat**: the exact
  Akamas YAML syntax for `type: ordinal` was not confirmed from any fetchable raw
  pack-source YAML — used `domain: {type: ordinal, categories: [...]}` by direct
  analogy with `categorical`, consistent with two other real Akamas packs
  (`aws_ec2_instance_size`, `v8_max_semi_space_size_ordinal`) that use `ordinal` for the
  same shape of problem, per rendered docs tables only. **Not yet validated against a
  live Akamas instance** — no `akamas` CLI was available in the environment this work
  was done in; run `akamas build optimization-pack`/`akamas describe optimization-pack
  vLLM` before relying on this in a real study, per `.claude/rules/akamas-yaml.md`. If
  the syntax is rejected, the documented fallback is reverting to `categorical` with
  categories left in ascending order.
- **New: `decode_context_parallel_size`** (integer `[1,16]`, default `1`) and
  **`prefill_context_parallel_size`** (integer `[1,8]`, default `1`) — vLLM's DCP/PCP
  flags (`--decode-context-parallel-size`/`-dcp`, `--prefill-context-parallel-size`/
  `-pcp`), verified directly against `vllm/engine/arg_utils.py` and
  `vllm/config/parallel.py` at the `v0.22.0` tag. These are the "context parallelism"
  parameters this repo's `ROADMAP.md` had tracked as a pack-request gap since
  `2026-07-distributed-inference-scaling-dimensions.md` first flagged them — now closed.
- **Definitively resolved as absent from vLLM `v0.22.0`** (exhaustive source grep, not
  a guess): `swap_space` (flag fully removed — `vllm/entrypoints/llm.py` now pops the
  kwarg and warns it's "deprecated and ignored"), `scheduler_delay_factor` (zero
  occurrences anywhere in source), `max_seq_len_to_capture` (zero occurrences; the
  pack's existing `max_cudagraph_capture_size` already covers the equivalent modern
  mechanism, `cudagraph_capture_sizes`), and a **KV-cache preemption threshold** (no
  such flag exists at all — preemption is purely automatic on KV-block allocation
  failure, `vllm/v1/core/sched/scheduler.py`, not exposed as a tunable). These are no
  longer open questions for the pack owner — they're confirmed non-existent in this
  vLLM version, not just "not yet checked."
- **Speculative decoding remains unresolved, but with a much sharper reason why**:
  `--spec-method`/`--spec-tokens` are real, decomposable scalar vLLM flags, but
  *disabling* speculation requires **omitting the flags entirely** — vLLM's
  `SpeculativeMethod` enum (`vllm/config/speculative.py`) has no literal "none"/"off"
  value. Akamas categorical/ordinal parameters are always-present (no "omit this
  argument" semantics), and this pack uses no `operators`-based conditional templating
  for any parameter — so a naive categorical `speculative_decoding_method` including a
  fake `"none"` value would either be silently wrong or need new pack-templating
  capability this pack doesn't have yet. Left as an open pack-request item, now with a
  concrete design blocker identified instead of just "missing."
- **Deliberately not attempted**: disaggregation/prefill-decode topology, MoE
  expert-count, EPLB toggles — confirmed (again) as deployment-architecture choices
  that may not belong in a per-instance component's parameter list at all, not
  force-fit into this pack.

## Reusable `parameterConstraints` — copy these into a study's manifest

The pack's own `README.md` now documents these in full (with source citations); the
formulas themselves, ready to paste into a study's `parameterConstraints:` list:

```yaml
parameterConstraints:
  # Existing (0-explorative's original 5, still valid — ordinal compares as quoted
  # strings the same way categorical did, so the block_size type change doesn't
  # affect these formulas)
  - name: FLASH_ATTN only supports auto kv_cache_dtype
    formula: vLLM.attention_backend != "FLASH_ATTN" || vLLM.kv_cache_dtype == "auto"
  - name: FlashInfer only supports block_size 16, 32, or 64
    formula: vLLM.attention_backend != "FLASHINFER" || vLLM.block_size == "16" || vLLM.block_size == "32" || vLLM.block_size == "64"
  - name: TRITON_ATTN does not support fp8 kv_cache_dtype on Ampere
    formula: vLLM.attention_backend != "TRITON_ATTN" || vLLM.kv_cache_dtype != "fp8"
  - name: TRITON_ATTN does not support fp8_e4m3 kv_cache_dtype on Ampere
    formula: vLLM.attention_backend != "TRITON_ATTN" || vLLM.kv_cache_dtype != "fp8_e4m3"
  - name: TRITON_ATTN does not support fp8_e5m2 kv_cache_dtype (query-quant bug)
    formula: vLLM.attention_backend != "TRITON_ATTN" || vLLM.kv_cache_dtype != "fp8_e5m2"

  # New — required whenever a study tunes decode_context_parallel_size
  - name: decode_context_parallel_size must evenly divide tensor_parallel_size
    formula: vLLM.tensor_parallel_size % vLLM.decode_context_parallel_size == 0

  # New — cluster-sizing template, NOT a fixed constant: replace <TOTAL_GPUS_AVAILABLE>
  # with the study's real GPU budget before use. Required whenever pipeline_parallel_size,
  # tensor_parallel_size, and prefill_context_parallel_size are tuned together.
  - name: Total GPU count must fit the cluster's GPU budget
    formula: vLLM.pipeline_parallel_size * vLLM.tensor_parallel_size * vLLM.prefill_context_parallel_size <= <TOTAL_GPUS_AVAILABLE>

  # New — efficiency only (not crash-causing): compilation_mode and
  # max_cudagraph_capture_size are both silently no-op'd whenever enforce_eager=true;
  # optional constraint to stop the optimizer wasting budget on redundant combinations.
  - name: compilation_mode and max_cudagraph_capture_size are no-ops under enforce_eager
    formula: vLLM.enforce_eager == "false" || (vLLM.compilation_mode == 0 && vLLM.max_cudagraph_capture_size == 256)
```

**Not encodable as a `parameterConstraints` formula** (documented in the pack README as
an open caveat instead): `decode_context_parallel_size > 1` requires either MLA
(`use_mla`) or a specific relationship between `tensor_parallel_size` and the model's
own `total_num_kv_heads`/`num_q_per_kv` (`vllm/config/model.py`) — none of those are
Akamas parameters (they come from the model's own config, not a tunable), so this
can't be a `vLLM.param1 op vLLM.param2` formula. For any non-MLA model (i.e. not
DeepSeek-family), either keep `decode_context_parallel_size == 1` or manually verify the
model's KV-head count supports the chosen value before including it in
`parametersSelection`. Related platform caveats (informational, not constraints): on
ROCm only, DCP/PCP > 1 silently downgrades `cudagraph_mode` from `FULL` to `PIECEWISE`;
DCP is incompatible with sliding-window models; PCP > 1 disables vLLM's "v2 model
runner" fast path.

## Implications for vLLM/k8s tuning

- **Directly closes `ROADMAP.md`'s context-parallelism pack-request gap** — a future
  multi-node or long-context study can now tune `decode_context_parallel_size`/
  `prefill_context_parallel_size` (subject to the constraints above, and Qwen2.5-7B's
  non-MLA architecture meaning `decode_context_parallel_size` should likely stay at 1
  for that specific model unless the KV-head/TP relationship is separately verified).
- **`block_size`'s ordinal conversion needs live validation before use** — don't assume
  it works on `akamas create -f` until confirmed against a real 3.7.x instance; if it's
  ever used in a study before that confirmation happens, note the risk explicitly in
  that study's README.
- **Several long-standing "still missing, check with pack owner" items in
  `ROADMAP.md`'s debt section are now resolved to "confirmed absent, not applicable"** —
  no further action needed on `swap_space`/`scheduler_delay_factor`/
  `max_seq_len_to_capture`/KV-cache-preemption-threshold; they're not vLLM `v0.22.0`
  capabilities at all, not a pack gap.
- **Speculative decoding stays the single highest-priority remaining pack gap**, now
  with a concrete design blocker (no "none" value, no conditional templating in this
  pack) rather than an open-ended "check if it's missing" — any future attempt to add
  it needs either a pack-level conditional-templating mechanism (checked with the pack
  owner/Akamas docs first) or a different decomposition (e.g. a boolean enable/disable
  parameter interpreted by study-level deploy tooling rather than passed straight
  through as a vLLM CLI flag).

## Which Akamas parameters to explore

`vLLM.decode_context_parallel_size` and `vLLM.prefill_context_parallel_size` are now
directly explorable, subject to the `parameterConstraints` above — relevant to any
future multi-GPU/multi-node study (see `ROADMAP.md` Section D, studies #7/#8). No
further pack action needed for `swap_space`/`scheduler_delay_factor`/
`max_seq_len_to_capture`/KV-cache-preemption-threshold (confirmed non-existent).
Speculative decoding remains N/A until a pack-templating solution is found — track as
the sole remaining high-priority pack-request item.
