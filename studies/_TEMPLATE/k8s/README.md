# k8s/ — this study's Kubernetes manifests

Whatever this study needs to apply: the workload under test (e.g. a serving
Deployment/Service, or a `.yaml.templ` template with `${Component.parameter}` tokens for
Akamas' FileConfigurator to render), the load-test job/manifest for whichever tool this
study uses, and any study-specific monitoring resources (e.g. a ServiceMonitor) not
already covered by shared cluster infra.

**The load generator is a per-study choice** — this repo has used GuideLLM, and NVIDIA's
GenAI-Perf/AIPerf is being evaluated as an alternative (see `ROADMAP.md` Q2). Put
whichever manifest this study actually uses here; don't copy another study's job
definition assuming the tool is the same.

This is a template placeholder — real studies replace this README with their actual
manifests (this note can stay or go once populated).
