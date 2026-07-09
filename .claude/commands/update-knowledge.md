---
description: Distill a paper, article, blog post, or vendor doc into a knowledge/notes/ entry and update the index
---

# update-knowledge

Add one new distilled note to the shared knowledge base. This is **not** paper-only —
articles, blog posts, vendor docs, and conference talks all go through the same
process. The user will hand you a URL, a pasted excerpt/text, or a local file path.

1. **Get the source content.**
   - URL: fetch it (WebFetch). If it's paywalled, JS-rendered, or otherwise unfetchable,
     ask the user to paste the relevant text instead of guessing at its content.
   - Pasted text: use it directly.
   - Local file (e.g. a PDF): read it. If it's worth keeping a durable local copy (a
     paper you'll reference repeatedly), save it under `knowledge/sources/`; for an
     ordinary web article, don't bother mirroring the whole page — the note's `Source:`
     link is enough.
2. **Check `knowledge/README.md`'s index first** — if this source (or a near-duplicate)
   already has a note, tell the user and ask whether to update the existing note instead
   of creating a new one.
3. **Copy `knowledge/notes/_TEMPLATE.md`** to `knowledge/notes/<slug>.md` — kebab-case,
   optionally date-prefixed (e.g. `2026-07-continuous-batching.md`).
4. **Fill in every section** by distilling, not summarizing-everything or pasting:
   - `Source` + `Date distilled`
   - `Problem addressed` — 2-4 sentences
   - `Levers / parameters touched` — the specific knobs the source discusses
   - `Key results` — concrete numbers/trends/thresholds, with the conditions they held
     under (hardware, model size, workload shape) — a finding without its conditions is
     not usable later
   - `Implications for vLLM/k8s tuning` — generalize carefully; this note is shared
     across studies that may use different stacks, so flag anything condition-specific
   - `Which Akamas parameters to explore` — map findings to concrete `vLLM.*` / `GPU.*` /
     Kubernetes component parameters. If the source implies a parameter/metric no
     installed optimization pack models, say so explicitly — check the pack's own repo
     (e.g. <https://gitlab.com/akamas/optimization-packs/vllm>) or run `akamas describe
     optimization-pack <name>`; that's a request for whoever manages packs (see the
     `akamas-optimization-pack` plugin), not something to build here.
   If a section genuinely doesn't apply, say so explicitly rather than leaving
   placeholder-shaped filler text.
5. **Add a row to `knowledge/README.md`'s index table**: note name/link, problem
   (one line), relevant Akamas parameters.
6. If the note surfaces something that should become a `ROADMAP.md` hypothesis or
   backlog idea, say so and ask before adding it — don't edit `ROADMAP.md` silently from
   this command.
7. Report back with the note's one-line takeaway — not the full distilled text.
