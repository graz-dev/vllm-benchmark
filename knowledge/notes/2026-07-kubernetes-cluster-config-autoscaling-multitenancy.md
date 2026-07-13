<!--
Template for a distilled knowledge note. Copy this file to a new name
(e.g. knowledge/notes/2026-07-continuous-batching.md), fill in every section,
then add a row to the index table in knowledge/README.md.
Keep it short — this is a distillation, not a summary of the whole source.
-->

# Kubernetes Cluster-Config Patterns: Autoscaling, Preemption, and Multi-Tenancy for GPU Inference

**Source:** [Autoscale AI inference with HPA and KEDA — Amazon EKS docs](https://docs.aws.amazon.com/eks/latest/userguide/ml-inference-autoscaling-hpa-keda.html),
[Autoscaling with KEDA — vLLM production-stack docs](https://docs.vllm.ai/projects/production-stack/en/latest/use_cases/autoscaling-keda.html),
[Pod Priority and Preemption — Kubernetes docs](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/),
[Disruptions — Kubernetes docs](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/),
[Specifying a Disruption Budget for your Application — Kubernetes docs](https://kubernetes.io/docs/tasks/run-application/configure-pdb/),
[Kueue — Kubernetes-native job queueing](https://kueue.sigs.k8s.io/),
[[RFC] Clarifying vLLM Shutdown Semantics — vllm-project/vllm#24885](https://github.com/vllm-project/vllm/issues/24885)
**Date distilled:** 2026-07-13

## Problem addressed

This repo's cluster runs a single vLLM replica with no autoscaling, no priority
classes, and no multi-tenant sharing. This note covers the standard patterns for
scaling and sharing a GPU cluster across teams/workloads: why CPU/memory-based HPA
doesn't fit GPU inference, how KEDA/Karpenter divide the scaling problem, whether
scale-down can safely kill in-flight requests (a risk this knowledge base already
flagged for NVIDIA Dynamo's Planner), and how PriorityClass/PDB/Kueue address
preemption safety and fair-share scheduling across tenants.

## Levers / parameters touched

Not vLLM parameters — cluster-level scaling and scheduling policy: KEDA `ScaledObject`
triggers/thresholds/windows, Karpenter node provisioning, `terminationGracePeriodSeconds`,
`PriorityClass`/`preemptionPolicy`, `PodDisruptionBudget` (`minAvailable`/
`unhealthyPodEvictionPolicy`), and Kueue `ClusterQueue`/`LocalQueue` quotas.

## Key results

- **HPA doesn't fit GPU inference**: a vLLM pod under load runs GPU near-saturated
  while CPU stays low, so CPU/memory-based HPA never fires even as requests queue
  (confirmed pattern; AWS's own EKS docs recommend the fix below rather than tuning HPA
  thresholds).
- **KEDA + Karpenter are complementary, not alternatives** — they scale different
  things. KEDA queries Prometheus directly and drives a standard HPA underneath,
  scaling on **queue depth** (vLLM's own `num_requests_waiting` metric — already
  exposed by this repo's telemetry) plus a p95-latency SLO guardrail, with
  **asymmetric windows**: scale-up fast (30s window, up to 2 pods/min), scale-down slow
  (300s window, 1 pod per 2 min) "because GPU pods are slow to start" — a documented,
  named pattern, not ad hoc tuning. Karpenter operates one layer down: it provisions/
  deprovisions **nodes**, triggered when KEDA-scaled pods go `Pending` for lack of GPU
  capacity. AWS's own docs describe this explicit hand-off: "KEDA scales the deployment
  up, and Karpenter provisions a new GPU node if none is available."
- **Scale-down killing in-flight requests is a general risk, not Dynamo-Planner-specific**
  (this knowledge base's existing Dynamo Planner note flagged this for that one tool
  specifically — now broadened): standard K8s scale-down goes through normal pod
  termination (Service endpoint removal → SIGTERM → `terminationGracePeriodSeconds` →
  SIGKILL), which *can* drain gracefully if `terminationGracePeriodSeconds` is generous
  enough (guidance: 60-120s up to 300-600s for streaming responses) and a `preStop`
  hook sleeps long enough for load-balancer deregistration to propagate first. **But**
  an open vLLM RFC (issue #24885) confirms vLLM's own SIGTERM handling has been
  **inconsistent historically** — it does not reliably wait for in-flight requests
  today; the RFC proposes fixing this upstream. So any KEDA/HPA-driven scale-down of
  vLLM pods carries this same risk until that upstream fix lands, not just
  autoscaler-specific logic.
- **PriorityClass/preemption**: `preemptionPolicy: Never` (stable since K8s 1.24) lets
  a pod queue-jump for scheduling without evicting anyone — the documented pattern for
  batch/training jobs sharing a GPU pool with inference (batch gets low priority +
  `preemptionPolicy: Never`, so it waits rather than steals GPUs; inference gets high
  priority so it *can* preempt if needed). **Critical caveat, from official K8s docs**:
  PDBs during preemption are **best-effort only** — "the scheduler tries to find victims
  whose PDB are not violated... but if no such victims are found, preemption will still
  happen." A PDB alone does **not** protect a slow-to-cold-start inference pod (this
  repo's own vLLM pods take 5-15 minutes to load) from being preempted — priority-value
  discipline is the actual control, not the PDB.
- **PDB for slow-starting pods**: set `unhealthyPodEvictionPolicy: AlwaysAllow` (K8s
  1.31+) so a slow-to-become-ready replacement pod doesn't itself block further
  voluntary-drain progress; the actual disruption *rate* during a drain is throttled by
  replacement pods' real startup time regardless of the PDB's numeric value — there's no
  official formula for "how conservative to set `minAvailable`" given a known 5-15 min
  load time, this is common practice (e.g. `maxUnavailable: 0`), not a documented
  standard.
- **Multi-tenancy/fair-share — Kueue** (official sigs.k8s.io project): a job-queueing
  *admission controller* in front of the scheduler, not a scheduler replacement.
  Provides `ClusterQueue`/`LocalQueue` for per-team GPU quota, automatic quota
  borrowing/lending across a cohort when idle, and priority-based preemption at
  *admission* time. Targets a gap plain Kubernetes has none of: no queueing, no quota
  governance ("one team can consume all GPUs while others wait"), no fair-share
  guarantee. Complements rather than replaces PriorityClass-based node-level preemption:
  Kueue governs admission fairness across tenants/namespaces; PriorityClass/preemption
  governs runtime eviction on a given node.

## Implications for vLLM/k8s tuning

- This repo's current single-replica studies don't need any of this — no autoscaling,
  no multi-tenant sharing, one pod per node. It becomes directly relevant the moment a
  future study introduces replica autoscaling (backlog #4/H4) or a shared cluster
  across multiple studies/teams.
- **The scale-down/in-flight-request risk generalizes beyond Dynamo's Planner** — this
  knowledge base's existing operating-practice note ("don't run autoscaling during a
  controlled Akamas experiment") should be read as applying to *any* autoscaler
  (KEDA/HPA included), not just Dynamo-specific tooling, until vLLM's own shutdown
  semantics (RFC #24885) are hardened upstream.
- If a future study does add autoscaling, KEDA's documented queue-depth signal
  (`num_requests_waiting`) is already a metric this repo's telemetry tracks — a natural
  scaling trigger to reuse rather than inventing a new one.
- Kueue is the concrete, named tool to reach for if this repo's cluster ever needs to
  host multiple concurrent studies/teams fairly — distinct from (and complementary to)
  the GPU-sharing mechanisms (MIG/time-slicing/MPS) covered in the companion
  Kubernetes-GPU-scheduling note in this knowledge base.

## Which Akamas parameters to explore

N/A — none of this is a vLLM/Akamas-tunable parameter; it's cluster-level scaling/
scheduling policy configured outside any optimization pack's `parametersSelection`.
Reinforces `ROADMAP.md`'s existing "don't run autoscaling during a controlled
experiment" operating practice (now with a generalized, sourced justification via the
vLLM SIGTERM RFC) and sharpens backlog #4's replica-count/HPA gap with concrete tool
names (KEDA for pod scaling, Karpenter for node provisioning, Kueue for multi-tenant
quota) to evaluate once that backlog item is scheduled.
