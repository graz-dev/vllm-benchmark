---
description: Scaffold a new, self-contained study folder under studies/ from studies/_TEMPLATE/
---

# new-study

Scaffold a new offline optimization study. Before writing anything:

1. Read `ROADMAP.md` (section B, the backlog table) and `knowledge/README.md`.
2. Ask the user (if not already clear from context):
   - **Study name** (short, matching a ROADMAP backlog entry if one exists — this
     becomes both the `studies/<name>/` folder name and the Akamas study's `name:`).
   - **Objective**: what metric to maximize/minimize, and any hard constraints (SLOs).
   - **Target component(s)**: which technology/technologies this study tunes — vLLM
     parameters, Kubernetes resource limits, GPU-related constraints, or a combination
     (see `ROADMAP.md` H4 for why combinations are interesting here). Don't assume
     vLLM-only by default; ask.
   - **Load generator**: which tool this study uses (GuideLLM, NVIDIA GenAI-Perf/AIPerf,
     something else) and its version — this is a per-study choice, not fixed by the
     repo (see `ROADMAP.md` Q2).
3. Copy the shape of `studies/_TEMPLATE/` into `studies/<name>/` (`README.md`, `akamas/`,
   `k8s/`, `results/`). Studies are fully self-contained by design — don't symlink or
   reference another study's files; duplicate what's needed instead (see root
   `README.md` on why).
4. Use the `akamas-study-manager` plugin (`/akamas-study-manager:build`) to generate
   the actual Akamas YAML inside `studies/<name>/akamas/` — don't hand-write it, and
   don't assume which optimization packs are installed; check first
   (`akamas list optimization-pack`).
5. Fill in `studies/<name>/README.md`'s `Objective`, `Stack & versions`, and `Parameters
   tuned` sections now (leave `Results`/`Conclusions` for `study-recap` at the end).
6. Add/update this study's row in `ROADMAP.md` section B with the real name and a link
   to `studies/<name>/README.md`, status `TODO`.
7. Add a row for this study to `studies/README.md`'s recap table (link to
   `studies/<name>/README.md`, `Configured as`/`Observed` left blank, `Status: TODO`).
8. Remind the user of the actual next step:
   `akamas create -f studies/<name>/akamas/` then `akamas start study "<name>"` — do not
   run these yourself unless asked, since starting a study consumes real compute/cost.
