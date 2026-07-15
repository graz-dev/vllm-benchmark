# infra/ — this study's cluster, from zero

This study is atomic: everything needed to go from an empty AWS account to a cluster
ready for the `akamas create`/`akamas start study` commands in this study's own
`README.md` lives here — nothing is assumed to already exist on a shared cluster.
Deliberately duplicated across studies rather than centralized (see the repo root
`README.md` on why studies are self-contained) — a future study with different
hardware (e.g. a different GPU generation or a multi-GPU node) gets its own
`infra/eks/cluster.yaml`, not a shared one this study could be broken by.

## Layout

- **`eks/cluster.yaml`** — the `eksctl` `ClusterConfig`: three managed node groups
  (`system` for Prometheus/Grafana, `akamas` for the Akamas platform itself if
  self-hosted, `llm-serving` for the GPU workload — tainted so only GPU pods schedule
  there).
- **`eks/storageclass.yaml`** — the default `gp3` StorageClass (Retain reclaim policy).
- **`eks/provision.sh`** — runs the whole bootstrap in order: cluster → kubeconfig →
  StorageClasses → NVIDIA device plugin → namespaces → this study's PVCs. Prints the
  remaining manual steps (monitoring stack, vLLM sanity-check deploy, Akamas study
  creation) at the end — see its own header comment and the study's main `README.md`.
- **`k8s-bootstrap/00-namespaces.yaml`** — the three namespaces this study uses
  (`llm-serving`, `llm-benchmark`, `monitoring`).
- **`k8s-bootstrap/01-storage-classes.yaml`** — the second StorageClass,
  `gp3-ephemeral` (Delete reclaim policy, for the re-downloadable model cache).

## Prerequisites (local tooling, not provisioned by this folder)

`eksctl`, `kubectl`, `aws` CLI (with credentials for an account that can create EKS
clusters/node groups/IAM roles), and `helm` (for the monitoring stack — installed
manually per `provision.sh`'s own printed next-steps, not automated in this pass).

## Usage

```bash
cd studies/0-explorative/infra/eks
./provision.sh                          # default region us-east-2
./provision.sh --region us-west-2       # different region (also edit cluster.yaml)
./provision.sh --profile my-aws-profile # named AWS CLI profile
```

## Teardown

```bash
# Stop GPU billing, keep the rest of the cluster (system/akamas nodes, Prometheus data):
eksctl delete nodegroup --cluster vllm-bench --region us-east-2 --name llm-serving --approve

# Full teardown:
eksctl delete cluster --name vllm-bench --region us-east-2
```

## What this does NOT cover

- The Akamas platform itself (assumed already installed/reachable — this repo's
  tooling doesn't manage the Akamas control plane).
- The `toolbox` host this study's Akamas workflow SSHes into to run `kubectl`/`helm`
  commands (see `../akamas/id_rsa` and the workflow YAML) — that host needs its own
  `kubectl` configured against this cluster and this repo checked out at the path the
  workflow references.
- Monitoring stack *installation* (Prometheus/Grafana/DCGM Exporter) — the Helm
  values/manifests are in `../k8s/monitoring/`, but installing them is a manual step
  printed by `provision.sh`, not yet scripted.
