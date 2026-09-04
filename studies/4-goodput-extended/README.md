# 4-Goodput-Extended

**Status:** TODO
**Dates:** —

## Objective

Not an optimization study — a **verification + extension** of `2-larger-model-g7e`'s
own best-found result. That study's optimize step found experiment 28
(`TRITON_ATTN` + `fp8_e4m3` + `gpu_memory_utilization≈0.904` + `max_num_seqs=1020` +
several other tuned values) scoring 18609.90 tokens/s, +57.41% over its own baseline —
see the CSV row this study was scaffolded from. This study asks two things with that
exact config, on the exact same hardware (`llm-serving-g7e`, RTX PRO 6000 Blackwell):

1. **Does it reproduce?** A `baseline` step pins experiment 28's config exactly (all
   14 tuned parameters from the CSV). The 12 "Pinned" (non-tuned) parameters from
   `2-larger-model-g7e`'s own README table are deliberately not referenced at all —
   see "Differences from 2-larger-model-g7e" below.
2. **Does pushing concurrency further help?** A `preset` step runs the identical
   config with `max_num_seqs` raised from 1020 to 2048, against a concurrency sweep
   extended to match (24 levels instead of 12, up to 2048 instead of 1024) — does the
   already-found optimum have more headroom at higher concurrency, or does it plateau/
   regress?

**No optimize step.** This study runs exactly these 2 fixed-configuration trials, no
search — see "Differences from 2-larger-model-g7e" below for the full list of what's
actually different; everything else (model, image, goal, windowing, node group) is
identical.

**Scaffolded 2026-09-04** from `2-larger-model-g7e` (`akamas/id_rsa` and
`results/export.gz` excluded, same convention as `3-comparison-a10`).

## Differences from `2-larger-model-g7e`

1. **Steps** — `baseline` (experiment 28's exact config) + `preset`
   (`max_num_seqs=2048`, otherwise identical). No `optimize` step.
2. **No `parametersSelection` / `parameterConstraints`** — nothing to search, and
   `max_num_seqs=2048` in the `preset` step is outside `2-larger-model-g7e`'s own
   domain for that parameter ([16, 1024]); omitting `parametersSelection` entirely
   avoids a domain conflict a pinned value there would otherwise cause. See the study
   YAML's own comment for the full reasoning.
3. **Only the 14 tuned parameters are referenced at all** — `k8s/01-deployment_template.yaml`
   has no `${vLLM.*}` token for any of the 12 "Pinned" parameters from
   `2-larger-model-g7e`'s own README table (`tensor_parallel_size`, `dtype`,
   `max_model_len`, etc.); their flags are simply absent from the command line, so
   vLLM applies its own real defaults unconditionally. Explicit user decision
   (2026-09-04): this sidesteps a genuine, never-resolved ambiguity
   `2-larger-model-g7e`'s own README flags about what these 12 actually rendered as
   during its optimize step ("whether they render at the value shown here during
   optimize depends on whether Akamas renders every component-declared parameter at
   its pack defaultValue by default ... this repo hasn't confirmed which") — rather
   than guess and pin a possibly-wrong value, this study just doesn't touch them.
4. **Concurrency sweep extended**: 24 levels instead of 12, geometrically spaced from
   150 (unchanged) to 2048 (double `2-larger-model-g7e`'s 1024) —
   `150,168,188,211,236,265,297,332,372,417,467,524,587,657,736,825,924,1036,1160,1300,1456,1632,1828,2048`.
   Explicit user decision: double the level *count*, not each existing value.
5. **Timeouts raised accordingly** — the load test now takes ~2x as long (24 x 300s
   levels instead of 12). `k8s/run_test_goodput.sh`'s `kubectl wait` timeout: 5700s
   (95m) → 9300s (155m). Workflow `RunTest` task timeout: 105m → 170m (same 15min
   margin convention).
6. **AIPerf job memory**: 6Gi/12Gi → 8Gi/13Gi (modest bump, not doubled — the
   `system` node only has ~14.36GiB allocatable total, shared with Prometheus/Grafana,
   so there's no room to double to 24Gi).
7. **Akamas resource names** renamed to keep every system/telemetry-instance/
   workflow/study name unique instance-wide: study `4-Goodput-Extended`, system
   `vLLM_Benchmark_4_Goodput_Extended`, telemetry instance
   `Prometheus_4_Goodput_Extended`, workflow `4-Goodput-Extended-Workflow`.

## Prerequisites before this study can be started

- Supply `akamas/id_rsa` (excluded from this scaffold — same as `3-comparison-a10`).
- Confirm the g7e node group (`llm-serving-g7e`) is on and `vllm-model-cache` lands in
  the same AZ (same recurring AZ-mismatch issue `2-larger-model-g7e` hit repeatedly).
- Check the shared AIPerf dataset cache
  (`/benchmarks/sharegpt-cache/inputs.json` on the `aiperf-results` PVC) has the
  correct model name baked in (`qwen2.5-7b`) before trusting the first real run —
  same class of stale-cache bug hit twice on `2-larger-model-g7e`.
- Validate `akamas/4-Goodput-Extended.yaml` against a live Akamas instance
  (`akamas create -f ...`) before declaring this study ready — not yet done for this
  scaffold. In particular, confirm Akamas accepts a `preset`-type step with a
  parameter value (`max_num_seqs=2048`) outside the pack's declared domain for that
  parameter — untested here.

## How to run

```bash
akamas create -f studies/4-goodput-extended/akamas/
akamas start study "4-Goodput-Extended"
```

## Results

<Filled in by the study-recap skill once the study finishes.>

## Conclusions

<Filled in by the study-recap skill once the study finishes.>
