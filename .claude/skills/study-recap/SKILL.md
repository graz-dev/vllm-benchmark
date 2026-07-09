---
name: study-recap
description: Close out a finished Akamas study — pull its data, write/update studies/<study>/README.md (objective, stack & versions, results, conclusions), update the studies/README.md recap table, and update ROADMAP.md's cross-study hypotheses/backlog/learnings. Use whenever a study finishes or the user asks to log/summarize results.
---

# study-recap

Run this after an Akamas study reaches a terminal state (all optimize-step experiments
done, or the user explicitly stopped it) and its results should be captured for future
reference.

## Procedure

1. **Get the study's raw data**, saved inside that study's own folder (studies are
   self-contained — see the root `README.md`).
   - If not already exported: `akamas export study "<name>" studies/<name>/results/export.tar.gz`
     (see the `akamas-study-manager` plugin's bundled `reference/akamas-cli.md`, or
     `akamas --help`).
   - Extract trial-level data: `akamas list trial "<name>" -o json > studies/<name>/results/trials.json`
     (or per-experiment: `akamas list trial "<name>" <experiment-id>`). Convert to
     `studies/<name>/results/trials.csv` if a CSV is more convenient to eyeball — a short
     Python snippet (`json.load` + `csv.DictWriter`) is fine, don't invent a heavier
     pipeline.
   - If timeseries data is needed for a chart (not just the aggregated trial score),
     it's inside the `export.tar.gz`.

2. **Identify the best trial(s).**
   - Sort by the study's `goal` direction (maximize/minimize) on the goal's formula
     value, respecting constraints — a trial that violates a constraint is not a
     candidate even if its raw objective value looks best.
   - Compute delta vs the `baseline` step's trial(s), not vs an arbitrary early trial.

3. **Write/update `studies/<name>/README.md`.** This file already exists (created by
   `/new-study` from `studies/_TEMPLATE/README.md`) — fill in its `Results` and
   `Conclusions` sections, and double-check `Stack & versions` reflects what actually
   ran (pack versions, load generator version, hardware) rather than what was planned.
   The template's structure is exactly:
   - **Objective** — already written when the study was scaffolded; leave as-is unless
     it turned out to be inaccurate.
   - **Stack & versions** — confirm/finalize: Akamas version, installed optimization
     pack(s) + version, workload image/model, cluster/hardware, load generator + exact
     version/invocation used, telemetry setup if non-default.
   - **Parameters tuned** — confirm the actual domains and baseline used.
   - **Results** — best configuration found (table: parameter, baseline, best trial),
     delta vs baseline on the goal metric, which constraints were binding, and a small
     table of the top N trials (or a description of the trend if no chart tool is
     available). Point to `studies/<name>/results/` for raw data rather than pasting it
     all in.
   - **Conclusions** — what was learned, generalizable takeaways, surprises, and what
     should happen next. Be explicit about what's generalizable vs specific to this
     study's exact stack (a future study may use a different model/GPU/load generator).
   Keep it factual and short — this is a record, not a report to management. Don't
   editorialize beyond what the numbers show.

4. **Update `ROADMAP.md`** with only what generalizes across studies:
   - **Section A (Hypotheses):** for every cross-study hypothesis this study was meant
     to test, move it from `[TO BE CONFIRMED]` to `[CONFIRMED]` or
     `[REJECTED — <one-line why>]`, citing `studies/<name>/README.md`. Don't leave stale
     `[TO BE CONFIRMED]` tags on hypotheses this study actually settled. If a finding
     only holds for this study's specific stack, say so instead of over-generalizing.
   - **Section B (Backlog):** mark this study's row `DONE` (linking to
     `studies/<name>/README.md`), and re-prioritize remaining rows if the results change
     what should come next (e.g. narrow a parameter domain a future study should use,
     drop a study that's now moot, add a follow-up study the results suggest).
   - **Section C (Learnings):** add a short bullet — the generalizable takeaway, not a
     repeat of the README's numbers, and note which study it came from.

5. **Update `studies/README.md`'s recap table**: find this study's row (added by
   `/new-study`, or add one now if missing), fill in `Configured as` (one line: target
   component(s) + the 2-3 parameters that matter + hardware/stack in brief) and
   `Observed` (one line: the headline result), and set `Status: DONE`. Pull the wording
   from `studies/<name>/README.md` rather than re-deriving it — this table is a pointer,
   not a second source of truth.

6. **Report back** with the study's headline result and what changed in `ROADMAP.md` and
   `studies/README.md` — not the full trial dump.

## When data can't be fully recovered

If the Akamas instance no longer has the study (deleted, different environment) but some
raw artifact still exists, say so explicitly in `studies/<name>/README.md` under a "Data
limitations" note rather than reconstructing numbers you don't have.
