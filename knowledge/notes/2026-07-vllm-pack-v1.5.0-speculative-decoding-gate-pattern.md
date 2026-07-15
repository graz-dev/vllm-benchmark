<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# vLLM Optimization Pack v1.5.1 — Speculative Decoding Gate Pattern

**Source:** direct pack-authoring work on
https://gitlab.com/akamas/optimization-packs/vllm, branch
`feature/attention-backend-and-block-size-categorical`, commits `ba048e4` (added the
parameters, as `1.5.0`) and `9e177fd` (renamed them to match this pack's own naming
convention, bumped to `1.5.1` — see "Naming correction" below; builds on
`2026-07-vllm-pack-v1.4.0-dcp-pcp-parameterconstraints.md`'s commit `2121136`).
Recorded here per this repo's convention of routing anything reusable-across-studies
through a knowledge note before it reaches a study manifest.
**Date distilled:** 2026-07-14, updated 2026-07-14

## Problem addressed

The previous pack pass (v1.4.0) left speculative decoding unimplemented because
*disabling* it in vLLM requires **omitting** CLI flags entirely — not passing a
"none"/"off" value — which doesn't fit Akamas' always-present categorical/ordinal
parameters. This note documents the general **gate-with-sentinel pattern** used to
close that gap, since it will recur for any future "on/off feature with dependent
sub-parameters" pack addition, not just this one.

## Levers / parameters touched

New: `vLLM.spec_method` (categorical gate) and `vLLM.spec_tokens` (dependent integer,
forced to an off-sentinel via `parameterConstraints` whenever the gate is `"none"`).

## Naming correction (2026-07-14, commit `9e177fd`)

Originally added as `speculative_decoding_method`/`num_speculative_tokens`. This broke
the pack's own established convention — verified against every other parameter in the
pack — that a parameter's name mirrors its vLLM CLI flag with hyphens replaced by
underscores (`attention_backend`←`--attention-backend`, `kv_cache_dtype`←
`--kv-cache-dtype`, `decode_context_parallel_size`←`--decode-context-parallel-size`,
etc., with zero exceptions among the other 28 parameters). The real vLLM CLI-facing
field names (`EngineArgs.spec_method`/`.spec_tokens`, confirmed directly from
`vllm/engine/arg_utils.py` lines 613-616 at the `v0.22.0` tag) are `spec_method` and
`spec_tokens` — neither matched what was first added.
`speculative_decoding_method` matched neither the CLI flag nor vLLM's internal
`SpeculativeConfig.method` field; `num_speculative_tokens` happened to match the
internal `SpeculativeConfig.num_speculative_tokens` field but not the CLI flag itself.
Renamed to `spec_method`/`spec_tokens` — now identical to vLLM's own CLI flags (minus
the leading `--` and hyphen-to-underscore conversion), same as every other parameter in
this pack. No behavior change, pure rename — safe to do since the branch was still
unpushed/unmerged when this was caught. The rest of this note uses the corrected names
throughout.

## Key results

- **vLLM `v0.22.0`'s speculative-decoding CLI is a hybrid, confirmed by reading
  `vllm/engine/arg_utils.py` and `vllm/config/speculative.py`**: only three flags are
  independent and flat — `--spec-method`, `--spec-model`, `--spec-tokens`. Every other
  `SpeculativeConfig` field (draft-model tensor-parallel size, quantization, ngram
  window bounds, suffix-decoding tuning, etc.) is reachable **only** through a single
  `--speculative-config`/`-sc` JSON-blob flag — there is no flat CLI flag for any of
  them, so none of those fields were added to the pack (assembling a JSON blob from
  several independent Akamas parameters at template-render time is exactly the kind of
  nested structure Akamas parameters can't cleanly express).
- **"Off" is a strict absence, not a value**: vLLM's `create_speculative_config`
  returns `None` only if *none* of `--speculative-config`/`--spec-method`/
  `--spec-model`/`--spec-tokens` were passed at all. Passing any one of them — even a
  placeholder — unconditionally triggers `SpeculativeConfig` construction and its
  Pydantic validation.
- **Why a sentinel value can never be passed through to vLLM itself (not a style
  choice — both would crash vLLM at startup)**: `--spec-method`'s argparse `choices`
  include the literal `"None"` (capital N) but never lowercase `"none"` — argparse
  itself rejects `--spec-method none` before vLLM's own code runs. `--spec-tokens` maps
  to `num_speculative_tokens: int = Field(default=None, gt=0)` — `0` is not a valid
  value for this field when actually set; rendering `--spec-tokens 0` raises a Pydantic
  `ValidationError` at engine startup. Both sentinels (`"none"`, `0`) are pure
  Akamas-side bookkeeping values with **zero vLLM-side meaning** — they exist only so
  Akamas' optimizer has something concrete to search over and constrain, and must be
  **dropped from the rendered command entirely**, never passed through.
- **The gate's value set was deliberately narrowed**, not left as vLLM's full
  `SpeculativeMethod` enum: `SpeculativeConfig.__post_init__` shows that when `method`
  is set without a draft-model `model` reference (exactly what this pack's flat
  `--spec-method`/`--spec-tokens` pair alone produces, since `--spec-model` was
  deliberately not added — its valid values are workload/target-model-specific, not a
  fixed pack-level domain), only four method values succeed without crashing:
  `mtp` (derives the draft config from the *same* target model checkpoint — only works
  if that checkpoint itself has MTP layers, e.g. DeepSeek-V3/V3.2, MiMo, GLM-4.5-MoE,
  Qwen3-Next families), `ngram`, `ngram_gpu`, and `suffix` (requires the optional
  `arctic-inference` package). Every other real method (`eagle`, `eagle3`, `medusa`,
  `mlp_speculator`, `draft_model`, `dflash`, `custom_class`) requires `--spec-model` and
  would crash vLLM at startup if selected through this pack alone — deliberately
  excluded, not overlooked. The 18 architecture-specific MTP aliases (`deepseek_mtp`,
  `mimo_mtp`, etc.) are collapsed to the canonical `mtp` (vLLM itself deprecates them
  to that value with a warning). `extract_hidden_states` was excluded as not an
  inference-speedup technique at all.
- **Final parameters**: `spec_method` — categorical
  `["none","ngram","ngram_gpu","suffix","mtp"]`, default `"none"`.
  `spec_tokens` — integer `[0,16]`, default `0`.

## The reusable pattern: gate parameter + forced-sentinel dependent

This is the general shape to reuse for any future "optional feature with dependent
sub-parameters" pack addition (not specific to speculative decoding):

1. **Gate parameter**: categorical, includes an explicit `"none"`/disabled value as
   one of its categories (not omitted — Akamas parameters are always present, so the
   "off" state needs its own real value to select).
2. **Dependent parameter(s)**: each gets a sentinel value that is only ever valid
   *inside Akamas' own bookkeeping* — verify from the real tool's source whether that
   sentinel would actually be rejected if rendered through (as it was here: `0` fails
   vLLM's own `gt=0` check) — if a sentinel happens to be independently valid to the
   underlying tool, this pattern still works but is less airtight (double-check whether
   dropping is still required or whether passthrough would be harmless in that case).
3. **Two-directional `parameterConstraints`** (both needed, not just one):
   ```yaml
   parameterConstraints:
     - name: <feature> disabled forces <dependent> to its off sentinel
       formula: vLLM.<gate> != "none" || vLLM.<dependent> == <sentinel>
     - name: <feature> enabled requires a real (non-sentinel) <dependent>
       formula: vLLM.<gate> == "none" || vLLM.<dependent> != <sentinel>
   ```
   The first stops the optimizer wasting experiment budget varying the dependent while
   the feature is off; the second stops it from ever selecting a real gate value
   together with the off-sentinel, which would crash the underlying tool.
4. **Drop-the-flag-entirely at deploy-render time** — a study's deployment/workflow
   script (not the pack) must check the gate's value and, if it's the disabled
   sentinel, **remove** the dependent flags from the rendered command rather than
   passing them with their sentinel values. This is the same shape of problem
   `0-explorative`'s own `apply_config.sh` already solves for boolean CLI flags (it
   rewrites templated `--flag=true`/`--flag=false` into bare `--flag`/`--no-flag` via
   `sed`) — a drop-if-sentinel step is a direct generalization of that existing
   precedent, not a new mechanism.

## Implications for vLLM/k8s tuning

- **Any future study that tunes `spec_method`/`spec_tokens`
  must implement the drop-flag step in its own deploy-rendering script** (e.g. a
  `sed`-based post-render pass, matching the pack's own README pseudocode) — this is
  not optional, passing the sentinel values through would crash vLLM at startup, not
  just behave oddly.
- **`mtp` is only usable on specific model families** (DeepSeek-V3/V3.2, MiMo,
  GLM-4.5-MoE, Qwen3-Next, and similar) — not applicable to this repo's
  Qwen2.5-7B-Instruct (a standard dense model without MTP layers). For that model,
  the only genuinely usable non-`"none"` values are `ngram`/`ngram_gpu` (no draft model
  needed, works on any model) or `suffix` (needs the optional `arctic-inference`
  package — confirm it's installed in the target image before including it in a
  study's domain, the same environment-precondition pattern already flagged for
  `prefix_caching_hash_algo`'s `xxhash` values).
- **Directly actionable for a RAG-shaped or code-completion-heavy future study**: per
  `knowledge/notes/2026-07-speculative-decoding-survey.md`, n-gram-style speculation
  (exactly `ngram`/`ngram_gpu` here) shows the largest speedups for high-repetition
  workloads — this pack addition makes that hypothesis directly testable for the first
  time, without needing a draft model.

## Which Akamas parameters to explore

`vLLM.spec_method` and `vLLM.spec_tokens` are now directly explorable, subject to (a)
the two `parameterConstraints` above, copied into any study using them, and (b) the
study's own deploy script implementing the drop-flag behavior.
`--spec-model`-dependent methods (`eagle`/`medusa`/etc.) remain unmodeled — adding them
would need a per-study, workload-specific draft-model reference, not a fixed pack-level
domain; revisit only if a future study specifically wants to benchmark one of those
methods against a known-compatible draft model.
