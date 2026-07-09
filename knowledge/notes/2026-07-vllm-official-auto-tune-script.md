<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# vLLM Official `auto_tune.sh` Benchmark Script

**Source:** [vllm-project/vllm — benchmarks/auto_tune](https://github.com/vllm-project/vllm/tree/main/benchmarks/auto_tune) (README)
**Date distilled:** 2026-07-08

## Problem addressed

vLLM's own upstream repo ships a bash-based grid-search script that automates finding
the throughput-maximizing combination of `gpu-memory-utilization`, `max-num-seqs`, and
`max-num-batched-tokens`, optionally subject to a P99 end-to-end latency SLA and a
minimum prefix-cache-hit-rate constraint. This is the **most authoritative** source in
this knowledge base for "which 3 parameters actually matter most and how vLLM's own
maintainers search them" — simpler and narrower than auto-tune-vllm's Optuna-based
approach (`knowledge/notes/2026-07-auto-tune-vllm.md`), but coming directly from the
vLLM project itself rather than a third party.

## Levers / parameters touched

- **`gpu-memory-utilization`**: not searched as a user-supplied range — the script
  **auto-calibrates** it by starting at 0.98 and decreasing until the server avoids
  OOM, i.e. it finds the maximum safe value automatically rather than sweeping a domain.
  Notably different from every other source in this knowledge base, which treats this as
  a value to search over a range (0.85–0.95 typically) — this script instead treats it as
  "find the ceiling, then fix it" and searches the other two parameters at that ceiling.
- **`max-num-seqs`** and **`max-num-batched-tokens`**: swept combinatorially (every
  pairing) over user-supplied space-separated lists, e.g. `NUM_SEQS_LIST="128 256"`,
  `NUM_BATCHED_TOKENS_LIST="1024 2048 4096"`.
- **`MAX_LATENCY_ALLOWED_MS`**: a P99 end-to-end-latency SLA constraint; for each
  parameter combination, the script runs at infinite request rate first, and only if
  that violates the latency budget does it back off request rate iteratively until the
  constraint is met — the recorded throughput is the constrained maximum, not the raw
  unconstrained one. Set to a very large number (e.g. `100000000000`) to effectively
  disable the constraint.
- **`MIN_CACHE_HIT_PCT`**: a minimum prefix-cache-hit-rate constraint (0 disables it) —
  the only source so far in this knowledge base treating cache hit rate as a hard
  admission constraint on a valid configuration, not just an observed metric.
- Other run parameters: `MODEL`, `SYSTEM` (e.g. `TPU`), `TP` (tensor-parallel size),
  `INPUT_LEN`/`OUTPUT_LEN`, `MAX_MODEL_LEN` — these define the workload/model under
  test, not things being searched.

## Key results

- No hardware-agnostic universal numbers, but a concrete worked example: for one tested
  combination pair, throughput went from **9.8 req/s** at `(max_num_seqs=128,
  max_num_batched_tokens=2048)` to **12.5 req/s** at `(256, 2048)`, while P99 e2e
  latency stayed around **450ms** in both cases — i.e. `max_num_seqs` was the
  under-tuned parameter here (raising it improved throughput materially without
  breaching the latency constraint), while `max_num_batched_tokens` was already at a
  good value. This is from the script's own example run, tied to whatever
  model/hardware that example used (a `Llama-3.3-70B-Instruct` / TPU example is shown
  separately in the CLI usage, not necessarily the same run as this throughput number)
  — don't treat 9.8→12.5 req/s as a transferable magnitude, only the *pattern* (one
  parameter can be far more impactful than the other at a fixed operating point).
- Example CLI invocation shows a full override set:
  `MODEL=meta-llama/Llama-3.3-70B-Instruct SYSTEM=TPU TP=8 INPUT_LEN=128 OUTPUT_LEN=2048
  MAX_MODEL_LEN=2300 MIN_CACHE_HIT_PCT=0 MAX_LATENCY_ALLOWED_MS=100000000000
  NUM_SEQS_LIST="128 256" NUM_BATCHED_TOKENS_LIST="1024 2048 4096"` — notable that this
  official script explicitly supports **TPU** as a `SYSTEM`, not just NVIDIA GPUs
  (profile artifacts differ: `.xplane.pb` for TPU vs. `.json` for GPU) — a reminder this
  repo's GPU-only framing (per the installed GPU pack, confirm with
  `akamas describe optimization-pack GPU`) is an NVIDIA-specific choice, not a vLLM
  limitation.
- A separate example shows a long-context scenario config
  (`INPUT_LEN=1800, OUTPUT_LEN=20, MAX_MODEL_LEN=2048`) alongside a stricter-SLA example
  (`MAX_LATENCY_ALLOWED_MS=500`) and a cache-sensitive example (`MIN_CACHE_HIT_PCT=60`)
  — illustrating the same three parameters get tuned differently depending on whether
  the workload is long-input/short-output or the reverse, and whether prefix-cache reuse
  is expected to matter.

## Implications for vLLM/k8s tuning

- This is the **strongest available validation** that this repo's three most-discussed
  parameters (`gpu_memory_utilization`, `max_num_seqs`, `max_num_batched_tokens` — all
  three already in the installed Akamas vLLM pack) are in fact the ones vLLM's own
  maintainers consider the primary tuning surface, directly supporting H1/H2/H3's focus.
- The **auto-calibrate-then-fix `gpu_memory_utilization`** approach is a genuinely
  different strategy from every prior source's "search a range" framing, and is worth
  weighing against H2: rather than treating `gpu_memory_utilization` as a dimension an
  Akamas study searches jointly with the others, this script's approach suggests it
  could instead be *computed* once (max safe value for the model+hardware) and then held
  fixed while `max_num_seqs`/`max_num_batched_tokens` are searched — potentially a
  faster-converging study design if H2 (diminishing returns at the top of the range) is
  confirmed, since it removes one search dimension entirely rather than letting the
  optimizer rediscover "higher is usually better until instability."
- The **latency-SLA-first-then-relax-request-rate** search order (try unconstrained,
  back off only if needed) is a specific search *strategy*, not a parameter — relevant to
  how a study's `goal.yaml` constraints should be framed (an SLA as a hard filter on
  valid configurations, consistent with how Triton Model Analyzer
  (`knowledge/notes/2026-07-triton-model-analyzer.md`) also structures constraints vs.
  objectives) rather than as a soft weighted term.
- `MIN_CACHE_HIT_PCT` as a hard constraint is new territory for this knowledge base —
  no prior note treated prefix-cache hit rate as an admission gate on configuration
  validity; worth considering for a study whose workload has meaningful prompt reuse
  (e.g. a RAG-shaped benchmark), where a configuration that happens to tank cache hit
  rate shouldn't be allowed to win purely on throughput.

## Which Akamas parameters to explore

- `vLLM.gpu_memory_utilization`, `vLLM.max_num_seqs`, `vLLM.max_num_batched_tokens`
  (all already modeled) — no new pack request; this source is corroborating evidence
  that these three are the right primary focus for this repo's studies, and suggests an
  alternative study-design pattern worth considering: compute `gpu_memory_utilization`'s
  safe ceiling once (e.g. via a short calibration run or a fixed conservative value) and
  scope the Akamas `parametersSelection` to just `max_num_seqs` +
  `max_num_batched_tokens`, rather than searching all three jointly — a design choice
  for whoever scaffolds a study, not a pack gap.
- **Prefix-cache hit rate as a metric**: confirm whether the installed vLLM pack's
  telemetry already exposes a cache-hit-rate metric (this repo's own tracking at the time
  only mentioned "KV-cache usage" generically) — if a study wants to replicate this script's
  `MIN_CACHE_HIT_PCT`-style hard constraint in a `goal.yaml`, it needs the exact metric
  name from `akamas describe optimization-pack vLLM`, not just KV-cache *usage*
  (occupancy) which is a different signal from cache *hit rate* (reuse effectiveness).
