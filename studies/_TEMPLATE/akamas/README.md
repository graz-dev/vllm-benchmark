# akamas/ — this study's Akamas resources

Generate everything in this folder with the `akamas-study-manager` plugin
(`/akamas-study-manager:build`) — don't hand-write Akamas YAML. It handles the build
order (System → Component → Telemetry → Workflow → Study) and the resource shapes
(`system.yaml`, `components/*.yaml`, `telemetry/*.yaml`, the workflow file,
`study.yaml`).

Optimization packs (which component types/parameters/metrics exist) are **not**
configured here — they're managed outside this repo, via the `akamas-optimization-pack`
plugin against the pack's own repo (e.g.
<https://gitlab.com/akamas/optimization-packs/vllm> for vLLM).

This is a template placeholder — real studies replace this README with their actual
YAML files (this note can stay or go once populated).
