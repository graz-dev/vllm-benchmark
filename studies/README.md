# Studies index — recap

At-a-glance recap of every study: which folder, how it's configured, and what was
observed — "folder X holds study Y, configured like this, we observed Z". Full detail
(exact YAML, versions, raw data) lives in each study's own `README.md`; this table is
for scanning across studies without opening every folder.

This is a **factual recap**, not a plan — for what to try next, see `ROADMAP.md`
(section B is the forward-looking backlog; this table is the backward-looking record of
what's actually been built and found).

| Study folder | Status | Configured as | Observed |
|---|---|---|---|
| [0-explorative](0-explorative/README.md) | DONE | vLLM (16/26 params), Qwen2.5-7B-Instruct on 1x A10G, attention_backend/kv_cache_dtype/gpu_memory_utilization/max_num_seqs the levers that mattered | +12.5% throughput vs. baseline (`FLASHINFER`+`fp8_e4m3`+`block_size=32`), with lower latency and higher success rate too — not a trade-off |

## Maintaining this table

- **`/new-study`** adds a row when a study is scaffolded (`Configured as`/`Observed`
  left blank, `Status: TODO`).
- **`study-recap`** (invoked directly or via `/log-results`) fills in `Configured as`
  (one line: target component(s) + the 2-3 parameters that matter + hardware/stack in
  brief) and `Observed` (one line: the headline result) and flips `Status` to `DONE`,
  once a study finishes. Pull the exact wording from that study's own README rather than
  re-deriving it.
- Keep every cell to one line — link to `studies/<name>/README.md` for the rest. If a
  one-liner can't do a result justice, that's a sign the reader should follow the link,
  not a reason to expand this table.
