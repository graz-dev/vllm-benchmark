---
description: Close out a finished Akamas study — invokes the study-recap skill
---

# log-results

Invoke the `study-recap` skill (`.claude/skills/study-recap/SKILL.md`) for the study the
user names (or, if unambiguous, the most recently started study per `ROADMAP.md`
section B). Follow that skill's procedure exactly: pull data into
`studies/<study>/results/`, fill in `studies/<study>/README.md`'s Results and
Conclusions sections, update the study's row in `studies/README.md`'s recap table, then
update `ROADMAP.md` sections A/B/C.
