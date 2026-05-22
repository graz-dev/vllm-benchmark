# vllm-benchmark

End-to-end baseline for serving **meta-llama/Meta-Llama-3.1-8B-Instruct** on AWS EKS with **vLLM**, interacting with it via **Open WebUI**, load-testing with **GuideLLM**, and monitoring with **Prometheus + Grafana**.

---

## Manifest Validation Findings

Issues found and fixed in the original `infra/eks/` manifests:

| File | Issue | Fix |
|---|---|---|
| `cluster.yaml` | `app` (m6i.4xlarge) and `akamas` nodes unused for this use case | `app` removed; `akamas` kept; GPU node added directly |
| `cluster.yaml` | GPU node group missing entirely | `llm-serving` (g5.2xlarge) added with taint |
| `nodegroups.yaml` | Missing `nvidia.com/gpu=present:NoSchedule` taint | Added; vLLM tolerates it, everything else is excluded |
| `nodegroups.yaml` | Duplicated `tools`/`akamas` from `cluster.yaml` | Reduced to `llm-serving` only (now used for on-demand re-add only) |
| `nodegroups.yaml` | `volumeSize: 50` — too small for model weights | Increased to 100 GB (16 GB model + ~10 GB images) |
| `nodegroups.yaml` | No `amiFamily` | Added `amiFamily: AmazonLinux2` (EKS accelerated AMI with NVIDIA drivers) |
| `provision.sh` | `CLUSTER_NAME="jvm-bench"` (copy-paste from JVM project) | Fixed to `vllm-bench` |
| `provision.sh` | NVIDIA device plugin never installed | Added `kubectl apply` for device plugin DaemonSet |
| `provision.sh` | Region comment said `eu-west-1` | Fixed to `us-east-2` |

---

## Architecture Overview

```
AWS Region: us-east-2
└── EKS Cluster: vllm-bench (EKS 1.35)
    │
    ├── Node Group: system  (m6i.xlarge — 4 vCPU / 16 GB)
    │   ├── namespace: llm-serving
    │   │   └── Open WebUI          ← chat UI (port 80, NLB → public DNS)
    │   ├── namespace: monitoring
    │   │   ├── Prometheus          ← scrapes vLLM /metrics via ServiceMonitor
    │   │   └── Grafana             ← dashboards (port-forward :3000)
    │   └── namespace: llm-benchmark
    │       └── GuideLLM Job        ← sweep benchmark → PVC (benchmarks.json / .html)
    │
    ├── Node Group: akamas  (r6i.xlarge — 4 vCPU / 32 GB)    [optional]
    │
    └── Node Group: llm-serving  (g5.2xlarge — 8 vCPU / 32 GB / 1× A10G 24 GB VRAM)
            Taint: nvidia.com/gpu=present:NoSchedule
        └── namespace: llm-serving
            ├── vLLM Deployment     ← serves meta-llama/Meta-Llama-3.1-8B-Instruct
            └── Service: vllm:8000  ← OpenAI-compatible endpoint (/v1/chat/completions)
```

**Data flows:**

```
Browser → Open WebUI (NLB :80)
             │  HTTP /v1/chat/completions
             ▼
         vLLM Service (ClusterIP :8000)
             │  GPU inference on A10G
             │  exposes GET /metrics
             ▼
         Prometheus (scrape every 15 s) → Grafana dashboards

GuideLLM Job → vLLM Service → results → PVC (benchmarks.json + .html)
```

---

## GPU Availability — What Happens Automatically vs What You Must Do

| Step | Automatic? | Who does it |
|---|---|---|
| NVIDIA drivers in OS | ✅ Yes | AWS — pre-installed in EKS accelerated AMI (`amiFamily: AmazonLinux2`) |
| k8s-device-plugin DaemonSet | ❌ No | You — `kubectl apply` in `provision.sh` step 4 |
| `nvidia.com/gpu` visible as allocatable resource | After device plugin | device plugin advertises it to kubelet |

Without the device plugin, `kubectl describe node` shows no GPU resource and any pod requesting `nvidia.com/gpu: 1` stays in `Pending` indefinitely.

---

## Taints, Tolerations, and NodeSelector — Isolation Strategy

```
                    ┌─────────────────────────────┐
                    │   GPU Node (llm-serving)     │
                    │   Taint: nvidia.com/gpu=     │
                    │          present:NoSchedule  │
                    └─────────────────────────────┘
                              ▲         ▲
       Toleration alone ──────┘         │
       NodeSelector alone ──────────────┘
       Both together ──────── guaranteed placement

Pod            Taint Toleration    NodeSelector    Result
─────────────  ────────────────    ────────────    ──────────────────────────────
vLLM           ✅ yes              ✅ llm-serving  → always on GPU node
Prometheus     ❌ no               ❌ system       → rejected by taint + pinned to CPU
GuideLLM       ❌ no               ✅ system       → rejected by taint + pinned to CPU
NVIDIA plugin  ✅ yes (built-in)   (any)           → lands on GPU node, exposes resource
```

**Why both mechanisms are needed:**
- **Taint alone**: the GPU node repels everything without a toleration, but vLLM with a toleration could still land on a CPU node if the scheduler preferred it.
- **NodeSelector alone**: vLLM is pinned to the GPU node, but Prometheus or GuideLLM could still land on the GPU node and steal its CPU/RAM from vLLM.
- **Together**: bidirectional isolation — nothing enters the GPU node unless it has a toleration, and vLLM cannot leave it.

---

## HuggingFace Secret — Why It's Needed

Llama 3.1 8B Instruct is a "gated" model on HuggingFace. Meta requires you to:
1. Accept the license at <https://huggingface.co/meta-llama/Meta-Llama-3.1-8B-Instruct>
2. Use an authenticated token to download the weights

When the vLLM pod starts, it downloads ~16 GB of model weights from the HuggingFace Hub. It reads the `HUGGING_FACE_HUB_TOKEN` environment variable to authenticate. The Kubernetes Secret is the standard way to inject this token without hardcoding it in the manifest (never store secrets in Git).

Without the secret → vLLM crashes at startup with `HTTPError: 401 Client Error`.

---

## VRAM Budget — Llama 3.1 8B on A10G (24 GB)

| Item | Calculation | Size |
|---|---|---|
| Model weights (BF16) | 8 × 10⁹ params × 2 B/param | **16.0 GB** |
| GPU utilization cap | 24 GB × 0.90 (`--gpu-memory-utilization`) | **21.6 GB** reserved |
| Available for KV cache | 21.6 − 16.0 | **5.6 GB** |
| Max context length | `--max-model-len=8192` fits within KV budget | **8 192 tokens** |

The model fits comfortably on a single A10G. The 5.6 GB KV-cache headroom supports ~20–40 concurrent requests at typical ShareGPT lengths (512 input / 128 output tokens).

---

## Prerequisites

| Tool | Min version | Install |
|---|---|---|
| `eksctl` | 0.185 | `brew install eksctl` |
| `kubectl` | matches cluster | `brew install kubectl` |
| `aws` CLI | v2 | `brew install awscli` |
| `helm` | 3.14 | `brew install helm` |

**AWS permissions required:**
- `eks:*`, `ec2:*`, `iam:CreateRole`, `iam:AttachRolePolicy`, `cloudformation:*`
- GPU quota for `g5.2xlarge` in `us-east-2` (request via AWS Service Quotas → EC2 → "Running On-Demand G and VT instances" if at 0)

**HuggingFace:**
- Accept the Llama 3.1 license
- Create a token with **Read** access at <https://huggingface.co/settings/tokens>

---

## Step-by-Step Execution Guide

### Step 1 — Create the cluster

```bash
chmod +x infra/eks/provision.sh
./infra/eks/provision.sh
```

This script (steps 1-5):
1. Creates the EKS cluster with all three node groups (`system`, `akamas`, `llm-serving`)
2. Updates kubeconfig
3. Applies the GP3 StorageClass
4. Installs the NVIDIA device plugin DaemonSet
5. Creates the three namespaces

Expected duration: **15–25 minutes** (EKS control plane creation dominates).

Verify GPU is visible:

```bash
kubectl get nodes -L node-role
kubectl describe node -l node-role=llm-serving | grep -A8 "Allocatable"
# Must show: nvidia.com/gpu: 1
```

---

### Step 2 — Configure the HuggingFace token

```bash
kubectl create secret generic hf-token \
  --from-literal=token=hf_xxxxxxxxxxxxxxxxxxxx \
  --namespace llm-serving
```

> `k8s/llm-serving/00-hf-secret.yaml` is a template only. **Never commit a real token.**

---

### Step 3 — Deploy vLLM + Open WebUI

```bash
kubectl apply -f k8s/llm-serving/
```

This deploys vLLM, Open WebUI, and their services in a single command.

Watch vLLM startup (model download + load: 5–15 min on first run):

```bash
kubectl rollout status deploy/vllm -n llm-serving --timeout=15m
kubectl logs -f deploy/vllm -n llm-serving
```

Get the Open WebUI public URL:

```bash
kubectl get svc open-webui -n llm-serving
# EXTERNAL-IP column → AWS NLB DNS name (takes 1-2 min to provision)
# Open http://<EXTERNAL-IP> in your browser
```

Smoke-test vLLM directly:

```bash
kubectl port-forward svc/vllm 8000:8000 -n llm-serving &

curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.1-8b",
    "messages": [{"role": "user", "content": "Ciao! Chi sei?"}],
    "max_tokens": 64
  }'
```

---

### Step 4 — Install Prometheus + Grafana

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  -f k8s/monitoring/values-kube-prometheus.yaml

kubectl apply -f k8s/monitoring/servicemonitor.yaml
```

Open Grafana:

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# http://localhost:3000  →  admin / changeme
```

Useful vLLM metrics to plot:

| Metric | Description |
|---|---|
| `vllm:request_success_total` | Completed requests/s |
| `vllm:e2e_request_latency_seconds` | End-to-end latency histogram |
| `vllm:prompt_tokens_total` | Input token throughput |
| `vllm:generation_tokens_total` | Output token throughput |
| `vllm:gpu_cache_usage_perc` | KV-cache utilisation (0–1) |
| `vllm:num_requests_running` | Requests currently in flight |

---

### Step 5 — Run the GuideLLM benchmark

```bash
kubectl apply -f k8s/llm-benchmark/00-pvc.yaml
kubectl apply -f k8s/llm-benchmark/01-job.yaml
```

The job:
1. **Init container** polls `vllm:8000/health` every 10 s until vLLM is ready (prevents race condition)
2. Runs a **rate sweep** over the **ShareGPT** chat dataset
3. Saves `benchmarks.json` and `benchmarks.html` to the PVC

Watch progress:

```bash
kubectl logs -f job/guidellm-benchmark -n llm-benchmark
```

Expected duration: **20–40 minutes**.

---

### Step 6 — Retrieve benchmark results

```bash
kubectl run result-reader \
  --image=alpine --restart=Never \
  --overrides='{
    "spec": {
      "nodeSelector": {"node-role": "system"},
      "volumes": [{"name":"r","persistentVolumeClaim":{"claimName":"guidellm-results"}}],
      "containers": [{"name":"c","image":"alpine","command":["sleep","3600"],
        "volumeMounts":[{"name":"r","mountPath":"/benchmarks"}]}]
    }
  }' \
  -n llm-benchmark

kubectl cp llm-benchmark/result-reader:/benchmarks ./benchmark-results/
kubectl delete pod result-reader -n llm-benchmark

open ./benchmark-results/benchmarks.html
```

---

## Architectural Decisions

### Why separate `system` and `llm-serving` node groups?

**Cost and isolation.** GPU instances (`g5.2xlarge`, ~$1.21/h) cost 6× more than CPU instances (`m6i.xlarge`, ~$0.19/h). Separating them allows:
- **Cost control**: delete the GPU node group between benchmarks, keep the monitoring/UI stack alive at $0.30/h
- **Noisy-neighbour prevention**: without the taint, Prometheus or GuideLLM could land on the GPU node and steal CPU/memory from vLLM's tokenisation threads
- **Scheduling determinism**: the taint + toleration + nodeSelector combination guarantees that only vLLM (and the device plugin) ever runs on the GPU node

### Why a PVC for GuideLLM output?

Kubernetes Jobs are ephemeral — without a PVC the `benchmarks.json` / `benchmarks.html` files disappear when the pod terminates. With a `Retain` GP3 PVC, results survive restarts and cluster operations. To accumulate results across runs, parameterize `--output-path /benchmarks/<run-id>` in the Job spec.

### Why `--gpu-memory-utilization=0.90` instead of 1.0?

Setting utilization to 1.0 leaves no headroom for CUDA library overhead (~200–400 MB), runtime memory fragmentation, and BF16 weight padding. 0.90 is the vLLM default and is safe. You can raise it to 0.95 for throughput experiments, but OOM kills become more likely.

### Why ShareGPT for the benchmark dataset?

ShareGPT contains real multi-turn human-AI conversations with a bimodal length distribution (short follow-ups + long context dumps). Synthetic uniform datasets produce misleading latency percentiles because vLLM's continuous batching strategy behaves very differently under variable-length inputs.

### Why a LoadBalancer service for Open WebUI?

Port-forwarding is acceptable for a single operator but impractical for a team reviewing benchmark results together. An NLB provides a stable DNS name and is the simplest external access pattern on EKS that doesn't require installing an Ingress controller. Cost: ~$0.008/h (negligible). To restrict access to your IP, add a security group rule on the NLB after provisioning.

---

## Cost Estimate

| Resource | Type | $/h (on-demand, us-east-2) |
|---|---|---|
| EKS control plane | — | $0.10 |
| `system` node | m6i.xlarge | $0.19 |
| `akamas` node | r6i.xlarge | $0.25 |
| `llm-serving` node | g5.2xlarge | $1.21 |
| EBS gp3 (~200 GB total) | — | ~$0.02 |
| NLB (Open WebUI) | — | ~$0.01 |
| **Total (GPU up)** | | **~$1.78/h** |
| **Total (GPU down)** | | **~$0.57/h** |

A full benchmark run takes 30–60 minutes: **~$0.89–$1.78 per run**. Delete the GPU node group when not actively benchmarking.

---

## Troubleshooting

**vLLM pod stuck in `Pending`**

```bash
kubectl describe pod -l app=vllm -n llm-serving
# "Insufficient nvidia.com/gpu" → device plugin not running
kubectl get daemonset nvidia-device-plugin-daemonset -n kube-system
kubectl describe node -l node-role=llm-serving | grep -A8 Allocatable
```

**vLLM in `CrashLoopBackOff`**

```bash
kubectl logs deploy/vllm -n llm-serving --previous
# 401/403 from HuggingFace → invalid or missing hf-token secret
# OOM → reduce --max-model-len or increase --gpu-memory-utilization carefully
```

**Open WebUI shows no models**

The UI reads available models from `GET /v1/models`. If the list is empty, vLLM is not reachable:
```bash
kubectl exec -it deploy/open-webui -n llm-serving -- \
  curl -s http://vllm.llm-serving.svc.cluster.local:8000/v1/models
```

**Prometheus not scraping vLLM**

```bash
kubectl get servicemonitor -n monitoring
# Verify serviceMonitorSelectorNilUsesHelmValues: false is set in Helm values
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
# http://localhost:9090/targets → look for errors on llm-serving/vllm
```

---

## Stop GPU Billing (Keep Cluster Alive)

```bash
eksctl delete nodegroup \
  --cluster vllm-bench \
  --region us-east-2 \
  --name llm-serving

# Re-add GPU node before next benchmark run:
# eksctl create nodegroup -f infra/eks/nodegroups.yaml
# kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml
```

## Full Teardown

```bash
eksctl delete cluster --name vllm-bench --region us-east-2
# EBS volumes with reclaimPolicy: Retain must be manually deleted from the AWS console.
```

---

## Repository Layout

```
.
├── infra/
│   └── eks/
│       ├── cluster.yaml                   # EKS cluster + all node groups (system, akamas, llm-serving)
│       ├── nodegroups.yaml                # llm-serving GPU node only — for on-demand re-add
│       ├── storageclass.yaml              # GP3 default StorageClass (Retain, WaitForFirstConsumer)
│       └── provision.sh                   # One-shot provisioning script
└── k8s/
    ├── 00-namespaces.yaml                 # llm-serving, llm-benchmark, monitoring
    ├── llm-serving/
    │   ├── 00-hf-secret.yaml             # HuggingFace token secret (template — do not commit token)
    │   ├── 01-deployment.yaml            # vLLM (GPU, taint toleration, startup probe, /dev/shm)
    │   └── 02-service.yaml               # ClusterIP on :8000
    ├── open-webui/
    │   ├── 00-pvc.yaml                   # 5 GB PVC for chat history + settings
    │   ├── 01-deployment.yaml            # Open WebUI (CPU node, connects to vLLM via ClusterIP)
    │   └── 02-service.yaml               # LoadBalancer (NLB) on :80
    ├── llm-benchmark/
    │   ├── 00-pvc.yaml                   # 10 GB PVC for benchmark results
    │   └── 01-job.yaml                   # GuideLLM sweep Job (sharegpt, init-wait for vLLM)
    └── monitoring/
        ├── values-kube-prometheus.yaml   # Helm values (node pinning, GP3 storage, cross-NS scraping)
        └── servicemonitor.yaml           # Scrape vLLM /metrics every 15 s
```
