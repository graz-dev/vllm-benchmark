# 1-Goodput-Realistic-Load — results

Raw export: `export.gz` (Akamas `export study` bundle — study/experiment/trial JSON plus
per-metric time series). Trial-level table: `trials.csv` (baseline + 30 optimize
experiments, correct experiment numbering — see the caveat below). Full deep-dive
analysis: **[report.html](report.html)** — open it directly in a browser
(self-contained, no server needed).

**Headline**: best trial (experiment 29, `FLASHINFER` + `kv_cache_dtype=fp8` +
`gpu_memory_utilization≈0.92` + `max_num_seqs≈770`) beat the baseline by **+45.5%**
goodput (3131 vs. 2152 tokens/s) while staying within both the 1500ms TTFT P95 and
300ms ITL P95 SLA constraints — Akamas' `stability` windowing selects the best
SLA-compliant sub-window from each trial's concurrency sweep, not a whole-trial
average. See the report for per-parameter effects and the full picture; the study's
own [README.md](../README.md) has the narrative (incidents, `parameterConstraints`
rationale, manual verification runs).

**Data-quality note**: this bundle's `last-optimization.json` array-to-experiment
mapping is `index + 2` (baseline excluded from the arrays), not the `index + 1` the
`akamas-study-analyzer` plugin's bundled tooling assumes — verified against
`logs.json`'s own per-experiment score log lines. See the report's "Caveats" section
and the study README's "Data-quality notes" for the full story.
