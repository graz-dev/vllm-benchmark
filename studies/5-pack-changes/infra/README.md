# infra/ — this study's cluster, from zero

This study is atomic: everything needed to go from an empty AWS account to a cluster
ready for the `akamas create`/`akamas start study` commands in this study's own
`README.md` lives here — nothing is assumed to already exist on a shared cluster.
Deliberately duplicated across studies rather than centralized (see the repo root
`README.md` on why studies are self-contained).

**This study deliberately targets the same cluster and the same A10G node group as
`0-explorative`/`1-goodput-realistic-load`/`3-comparison-a10`** (same name
`vllm-bench`, same region `us-east-2`, same `llm-serving`/`g5.2xlarge` node group) —
cloned directly from `3-comparison-a10`'s own infra, unchanged. A10G was chosen
specifically because it's the cheaper of this repo's two GPU node groups (vs. the
`llm-serving-g7e` RTX PRO 6000 Blackwell group `2-larger-model-g7e` uses) — this study
only needs *a* working vLLM+DCGM+Prometheus stack to verify the new pack metrics
collect, not any particular hardware's performance characteristics.
`provision.sh` detects whether the cluster and this node group already exist and only
creates what's missing — it never adds a new node group of its own. If the
`llm-serving` group is currently scaled down (`desiredCapacity: 0`), scale it back up
before running this study rather than reprovisioning anything.

## Layout

- **`eks/cluster.yaml`** — the full `eksctl` `ClusterConfig` for the `vllm-bench`
  cluster: `system`/`akamas` node groups plus the single GPU node group this study
  actually uses, `llm-serving` (`g5.2xlarge`, A10G) — identical to
  `1-goodput-realistic-load`'s own `cluster.yaml`. No `llm-serving-g7e` group here;
  that belongs to `2-larger-model-g7e` only.
- **`eks/storageclass.yaml`** — the default `gp3` StorageClass (Retain reclaim policy).
- **`eks/provision.sh`** — creates the cluster if it doesn't exist yet (all node
  groups), or, if it already exists, ensures `llm-serving` is present/scaled up. Then
  applies StorageClasses, the NVIDIA device plugin, namespaces, and (once populated)
  this study's PVCs. Prints remaining manual steps at the end.
- **`k8s-bootstrap/00-namespaces.yaml`** — the three namespaces this study uses
  (`llm-serving`, `llm-benchmark`, `monitoring`) — identical to prior studies, applied
  idempotently (`kubectl apply` no-ops if they already exist from an earlier study).
- **`k8s-bootstrap/01-storage-classes.yaml`** — the second StorageClass,
  `gp3-ephemeral` (Delete reclaim policy, for the re-downloadable model cache).

## Prerequisites (local tooling, not provisioned by this folder)

`eksctl`, `kubectl`, `aws` CLI (with credentials for an account that can create/modify
EKS node groups), and `helm` (for the monitoring stack, already installed on this
cluster from `0-explorative`'s provisioning if reusing `vllm-bench`).

## Usage

```bash
cd studies/5-pack-changes/infra/eks
./provision.sh                          # default region us-east-2
./provision.sh --region us-west-2       # different region (also edit cluster.yaml)
./provision.sh --profile my-aws-profile # named AWS CLI profile
```

## Teardown

```bash
# Scale the shared A10G node down instead of deleting it — 0-explorative and
# 1-goodput-realistic-load use the same node group.
eksctl scale nodegroup --cluster vllm-bench --region us-east-2 --name llm-serving --nodes 0

# Full cluster teardown — CAUTION: this removes every study's node groups, since they
# all share this same cluster (including 2-larger-model-g7e's own llm-serving-g7e).
# Confirm no other study still needs it before running this.
eksctl delete cluster --name vllm-bench --region us-east-2
```

## What this does NOT cover

- The Akamas platform itself (assumed already installed/reachable).
- The `toolbox` host this study's Akamas workflow SSHes into to run `kubectl`/`helm`
  commands — needs its own `kubectl` configured against this cluster and this repo
  checked out at the path the workflow references (see `1-goodput-realistic-load`'s own
  `infra/README.md` for the precedent this follows).
- Monitoring stack *installation* — already done on this cluster from
  `0-explorative`'s provisioning if reusing `vllm-bench`. This study reuses the
  existing `dcgm-exporter` release and `ServiceMonitor` unchanged from
  `3-comparison-a10` — nothing new to apply here. The one live infra change this study
  did require (`kube-state-metrics`'s node-label allowlist, needed for the
  cluster-level PSI metrics' node join) is documented in the main `README.md`'s "New
  metrics" section, not here — it's a change to shared monitoring config, not to this
  study's own cluster provisioning.
