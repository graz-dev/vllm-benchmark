---
description: Conventions and safety checks for Akamas resource YAML in this repo
globs: "studies/**/akamas/**"
---

# Akamas YAML rules (studies/**/akamas/**)

- **Use the `akamas-study-manager` plugin** (`/akamas-study-manager:build`) for anything
  under a study's `akamas/` folder — don't hand-write Akamas YAML from memory.
- **No optimization pack files in this repo.** Pack lifecycle (component types,
  parameters, metrics) is managed outside this repo, via the `akamas-optimization-pack`
  plugin against the pack's own repo (e.g. <https://gitlab.com/akamas/optimization-packs/vllm>
  for vLLM) — never add an `optpack/`-style folder or a pack manifest under a study. If a
  parameter/metric is missing, note it as a TODO in that study's `README.md` and raise it
  with whoever manages packs.
- **Naming**: component names must match `^[a-zA-Z][a-zA-Z0-9_]*$` (letters/digits/
  underscores, must start with a letter — no hyphens, no leading digit/underscore).
  Study/system/workflow names may contain spaces or hyphens — keep each study's Akamas
  resource names unique to that study (systems, telemetry instances, and workflows are
  not shared across `studies/` folders here).
- **`kind` key**: only add `kind:` (and, for system-scoped resources, `system:`) when the
  file is meant to be created via `akamas create -f`. If a file is meant for the
  explicit-resource-type CLI form (`akamas create study study.yaml`), leave those keys
  out — don't cargo-cult them onto every file "just in case".
- **Parameter domains**: a study's `parametersSelection[].domain` must fit *inside* the
  installed component-type's own domain — check with `akamas describe optimization-pack
  <name>` before writing a domain, don't assume it matches another study or a template.
- **No secrets in YAML**: never put a real SSH private key, password, or API token
  directly in a workflow task's `key:`/`password:` field or commit a key file under
  `studies/`. Reference a path outside the repo, or a secret manager, and leave a `TODO`
  comment naming what's needed. This repo's git history already has one compromised key
  (see `ROADMAP.md` security debt) — don't add another.
- **Validate before saying "done"**: run (or ask the user to run, if you lack CLI
  access) `akamas create -f <file>` — or at minimum `akamas describe <resource-type>
  <name>` after creation — against a real Akamas instance before reporting a YAML change
  as complete. There is no offline schema validator; the `akamas-study-manager` plugin's
  bundled schema reference is a fallback for shape/field checks, not a substitute.
- **Study edits on a running study**: on Akamas 3.7.x, only the `goal` (formula/
  objective/constraints) can be edited without losing history, via
  `akamas update study <name> <file>`. Changing `parametersSelection`, `windowing`, or
  `steps` on an existing study requires a new study — don't attempt to hand-edit those
  on a study that has already run experiments.
