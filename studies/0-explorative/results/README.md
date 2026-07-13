# 0-Explorative — results

Raw export: `export.gz` (Akamas `export study` bundle — study/experiment/trial JSON plus
per-metric time series). Full deep-dive analysis: **[report.html](report.html)** — open it
directly in a browser (self-contained, no server needed).

**Headline**: best trial (experiment 21, `FLASHINFER` + `kv_cache_dtype=fp8_e4m3` +
`block_size=32`) beat the baseline by **+12.5%** on the throughput goal, with lower latency
and higher success rate too — not a trade-off. See the report for per-parameter effect
breakdowns (including side effects beyond the goal metric), parameter interactions, and a
timeseries deep-dive; see the study's own [README.md](../README.md) for the narrative
(incidents, `parameterConstraints` rationale, manual verification runs).
