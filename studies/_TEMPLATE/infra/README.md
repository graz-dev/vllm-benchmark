# infra/ — this study's cluster, from zero

**Every study is atomic, including cluster provisioning** (decided 2026-07-15) — a
study's own `infra/` folder must be able to take an empty AWS account to a cluster
ready for `akamas create`/`akamas start study`, without assuming anything already
exists on a shared cluster. Copy `studies/0-explorative/infra/` as the concrete
reference (it's the first study built this way) and adapt every hardware-specific
detail — don't assume this study's GPU/instance type, node group layout, or even
cloud provider is the same as another study's.

## Expected layout (mirror `0-explorative`'s, adapt the contents)

- **`eks/cluster.yaml`** — the `eksctl` `ClusterConfig` for *this study's* hardware
  (GPU type/instance size, node group count, region). Don't copy another study's
  instance type without checking `ROADMAP.md` Section D for what this study is
  actually supposed to test.
- **`eks/storageclass.yaml`** — the default StorageClass.
- **`eks/provision.sh`** — one script, idempotent, that creates the cluster, updates
  kubeconfig, applies StorageClasses, installs the GPU device plugin (or configures
  DRA — see `ROADMAP.md`'s DRA prerequisites section if this study uses it), applies
  namespaces, and applies this study's own PVCs. Prints remaining manual steps
  (monitoring stack, Akamas study creation) at the end.
- **`k8s-bootstrap/00-namespaces.yaml`**, **`k8s-bootstrap/01-storage-classes.yaml`** —
  cluster-wide Kubernetes resources needed before any study-specific manifest applies.

## What every study's `infra/README.md` should cover

Prerequisites (local CLI tooling + AWS permissions needed), usage (`provision.sh`
invocation + flags), teardown commands (both "pause GPU billing" and "full teardown"),
and an explicit "what this does NOT cover" section (the Akamas platform itself, the
`toolbox` host used by the workflow, monitoring-stack *installation* if that's still a
manual step).

This is a template placeholder — real studies replace this README with their actual
`eks/`/`k8s-bootstrap/` files and a filled-in version of this README (this note can
stay or go once populated).
