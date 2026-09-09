# infra/ — this study's cluster, from zero

This study is atomic: everything needed to go from an empty AWS account to a cluster
ready for the `akamas create`/`akamas start study` commands in this study's own
`README.md` lives here — nothing is assumed to already exist on a shared cluster.
Deliberately duplicated across studies rather than centralized (see the repo root
`README.md` on why studies are self-contained).

**This study needs a NEW GPU node group, `llm-serving-l4`** (g6.12xlarge, 4x NVIDIA L4
24GB) — **created 2026-09-07** (`eksctl create nodegroup --config-file=... --include=
"llm-serving-l4,system-m8a"`, profile `lab`; no manual `ami:` pin needed — eksctl
recognized `g6` and auto-selected the NVIDIA AMI, unlike the `g7e` gap
`2-larger-model-g7e` hit). Same cluster (`vllm-bench`), same region (`us-east-2`) as
every other study. `provision.sh` detects whether the cluster and this node group
already exist and only creates what's missing — it never touches the existing
`akamas`/`llm-serving`/`llm-serving-g7e` node groups (nor the pre-existing, untracked
`m7i-2xlarge`/`m8a-2xlarge` node groups found already on this cluster at provisioning
time — unrelated to this study, left alone).

**`system-m8a` — created AND migrated to, same day.** The candidate replacement for
the shared `system` node group (`m6i.xlarge` → `m8a.xlarge`, per explicit request) was
created alongside `llm-serving-l4`, then the entire shared monitoring/ingress stack was
migrated onto it: `cert-manager` (Helm, 3 sub-nodeSelectors), `kube-prometheus-stack`
(Helm, 5: prometheus/alertmanager/grafana/kube-state-metrics/operator),
`nginx-ingress`, `external-dns`, `open-webui` (the last two are raw Deployments, not
Helm releases — nodeSelector patched directly). One real gotcha hit during migration:
`system-m8a`'s ASG initially came up in `us-east-2a` while `system`'s persistent
volumes (Prometheus/Grafana/open-webui, `Retain` policy) are in `us-east-2b` — fixed
the same way the `system` node group's own AZ mismatch was fixed earlier (pin the
ASG's `VPCZoneIdentifier` to the single `us-east-2b` subnet, cycle the node), verified
live via Prometheus's own scrape continuity (`count(up)` over the full migration
window, no gap) that no historical data was lost. A second gotcha: Grafana/open-webui
(Deployments with an RWO EBS volume) deadlocked on `RollingUpdate` — the new pod
couldn't attach the volume while the old pod on the other node still held it, and the
old pod wouldn't terminate until the new one was Ready. Fixed by directly scaling the
OLD ReplicaSet to 0 (not just deleting its pod, which the Deployment controller just
recreates) — a one-time manual unblock, not something `provision.sh` automates.

**`system` node group is now empty** (only DaemonSets remain: `aws-node`,
`kube-proxy`, `ebs-csi-node`, node-exporter, the NVIDIA device plugin) and can be
scaled to 0 (`eksctl scale nodegroup --name system --nodes 0`) once you're satisfied
nothing regressed. Not decommissioned automatically by anything in this repo — that's
a deliberate manual step, do it when ready.

## Layout

- **`eks/cluster.yaml`** — the full `eksctl` `ClusterConfig` for the `vllm-bench`
  cluster: `system` (existing, `m6i.xlarge`) + `system-m8a` (new, `m8a.xlarge`,
  `desiredCapacity: 0` — scaffolded only) + `akamas` (existing, unchanged) +
  `llm-serving` (existing A10G group, kept here as part of the full snapshot but not
  used by this study) + `llm-serving-l4` (new, `g6.12xlarge`, `desiredCapacity: 0` —
  scaffolded only). See the file's own comments for the AMI-selection caveat
  (`amiFamily: AmazonLinux2023` with no explicit `ami:` override — unverified for
  `g6`, confirmed to need a pin for `g7e` in `2-larger-model-g7e`).
- **`eks/storageclass.yaml`** — the default `gp3` StorageClass (Retain reclaim policy).
- **`eks/provision.sh`** — creates the cluster if it doesn't exist yet (all node
  groups), or, if it already exists, creates ONLY `llm-serving-l4` and `system-m8a` if
  they're missing — every other node group is left completely untouched. Then applies
  StorageClasses, the NVIDIA device plugin, namespaces, and this study's PVCs. Prints
  remaining manual steps at the end.
- **`k8s-bootstrap/00-namespaces.yaml`** — the three namespaces this study uses
  (`llm-serving`, `llm-benchmark`, `monitoring`) — identical to prior studies, applied
  idempotently (`kubectl apply` no-ops if they already exist from an earlier study).
- **`k8s-bootstrap/01-storage-classes.yaml`** — the second StorageClass,
  `gp3-ephemeral` (Delete reclaim policy, for the re-downloadable model cache).

## Prerequisites (local tooling, not provisioned by this folder)

`eksctl`, `kubectl`, `aws` CLI (with credentials for an account that can create/modify
EKS node groups), and `helm` (for the monitoring stack, already installed on this
cluster from `0-explorative`'s provisioning).

## Usage

```bash
cd studies/6-data-parallelism/infra/eks
./provision.sh                          # default region us-east-2
./provision.sh --region us-west-2       # different region (also edit cluster.yaml)
./provision.sh --profile my-aws-profile # named AWS CLI profile
```

After provisioning, verify the GPU actually came up correctly before trusting anything
downstream (this is the first study on this instance family in this repo):

```bash
kubectl describe node -l node-role=llm-serving-l4 | grep -A5 Allocatable
# Should show: nvidia.com/gpu: 4
```

If it doesn't, see `eks/cluster.yaml`'s own comment on the AMI-selection gap
`2-larger-model-g7e` hit for a different new instance family (`g7e`) — the fix there
was pinning `ami:` explicitly to the EKS-optimized AL2023 NVIDIA variant.

## Teardown

```bash
# Stop GPU billing without affecting other studies' node groups.
eksctl delete nodegroup --cluster vllm-bench --region us-east-2 --name llm-serving-l4 --approve

# Full cluster teardown — CAUTION: this removes every study's node groups, since they
# all share this same cluster (0-explorative/1-goodput-realistic-load/3-comparison-a10/
# 5-pack-changes' llm-serving, 2-larger-model-g7e's llm-serving-g7e, this study's
# llm-serving-l4). Confirm no other study still needs it before running this.
eksctl delete cluster --name vllm-bench --region us-east-2
```

## What this does NOT cover

- The Akamas platform itself (assumed already installed/reachable).
- The `toolbox` host this study's Akamas workflow SSHes into to run `kubectl`/`helm`
  commands — needs its own `kubectl` configured against this cluster and this repo
  checked out at the path the workflow references (see `1-goodput-realistic-load`'s own
  `infra/README.md` for the precedent this follows).
- Monitoring stack *installation* — already done on this cluster from
  `0-explorative`'s provisioning. This study needs its OWN DCGM Exporter release
  (`dcgm-exporter-l4`, see `k8s/monitoring/dcgm-exporter-values.yaml`), same pattern as
  `2-larger-model-g7e`'s `dcgm-exporter-g7e` — a single shared release can only target
  one node-role at a time.
- **Scaling `system` to 0** — done manually (`eksctl scale nodegroup`), not by
  anything in this repo, once you've confirmed the migration above is stable.
