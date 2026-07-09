# vllm-benchmark

End-to-end baseline for serving an LLM on AWS EKS with **vLLM**, interacting with it via **Open WebUI**, load-testing with **GuideLLM**, and monitoring with **Prometheus + Grafana**.

**Supported models (pre-configured, single A10G):**

| Model | HuggingFace ID | Gate | Status |
|---|---|---|---|
| Qwen 2.5 7B Instruct | `Qwen/Qwen2.5-7B-Instruct` | None — download immediately | ✅ **Default** |
| Llama 3.1 8B Instruct | `meta-llama/Meta-Llama-3.1-8B-Instruct` | Meta license approval required | 💤 Commented out |

To switch models, see [Switching Models](#switching-models).

---

## Architecture Overview

```
AWS Region: us-east-2
└── EKS Cluster: vllm-bench (EKS 1.35)
    │
    ├── Node Group: system  (m6i.xlarge — 4 vCPU / 16 GB)
    │   ├── namespace: monitoring
    │   │   ├── Open WebUI          ← chat UI (port 80, NLB → public IP)
    │   │   ├── Prometheus          ← scrapes vLLM /metrics via ServiceMonitor
    │   │   └── Grafana             ← dashboards (port-forward :3000)
    │   └── namespace: llm-benchmark
    │       └── GuideLLM Job        ← throughput benchmark → PVC (benchmarks.json)
    │
    ├── Node Group: akamas  (r6i.xlarge — 4 vCPU / 32 GB)    [optional]
    │
    └── Node Group: llm-serving  (g5.2xlarge — 8 vCPU / 32 GB / 1× A10G 24 GB VRAM)
            Taint: nvidia.com/gpu=present:NoSchedule
        └── namespace: llm-serving
            ├── vLLM Deployment     ← serves the active model (default: Qwen2.5-7B-Instruct)
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

GuideLLM Job → vLLM Service → results → PVC (benchmarks.json)
```

---

## GPU Availability — What Happens Automatically vs What You Must Do

| Step | Automatic? | Who does it |
|---|---|---|
| NVIDIA drivers in OS | ✅ Yes | AWS — pre-installed in EKS accelerated AMI (`amiFamily: AmazonLinux2023`) |
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

The vLLM toleration uses `operator: Exists` to match the node taint regardless of its value:

```yaml
tolerations:
  - key: nvidia.com/gpu
    operator: Exists   # matches any value — robust to taint value changes
    effect: NoSchedule
```

**Why both mechanisms are needed:**
- **Taint alone**: the GPU node repels everything without a toleration, but vLLM with a toleration could still land on a CPU node if the scheduler preferred it.
- **NodeSelector alone**: vLLM is pinned to the GPU node, but Prometheus or GuideLLM could still land on the GPU node and steal its CPU/RAM from vLLM.
- **Together**: bidirectional isolation — nothing enters the GPU node unless it has a toleration, and vLLM cannot leave it.

---

## VRAM Budget — A10G (24 GB)

### Qwen 2.5 7B Instruct (default)

| Item | Calculation | Size |
|---|---|---|
| Model weights (BF16) | 7 × 10⁹ params × 2 B/param | **~14.0 GB** |
| GPU utilization cap | 24 GB × 0.90 (`--gpu-memory-utilization`) | **21.6 GB** reserved |
| Available for KV cache | 21.6 − 14.0 | **~7.6 GB** |
| Max context length | `--max-model-len=8192` fits well within KV budget | **8 192 tokens** |

The extra ~2 GB of KV headroom compared to Llama translates to higher concurrent request capacity.

### Llama 3.1 8B Instruct (optional)

| Item | Calculation | Size |
|---|---|---|
| Model weights (BF16) | 8 × 10⁹ params × 2 B/param | **16.0 GB** |
| GPU utilization cap | 24 GB × 0.90 (`--gpu-memory-utilization`) | **21.6 GB** reserved |
| Available for KV cache | 21.6 − 16.0 | **5.6 GB** |
| Max context length | `--max-model-len=8192` fits within KV budget | **8 192 tokens** |

Both models fit comfortably on a single A10G. The 5.6–7.6 GB KV-cache headroom supports ~20–40 concurrent requests at typical benchmark lengths (512 input / 128 output tokens).

---

## Switching Models

All changes are confined to `k8s/llm-serving/01-deployment.yaml`.

### Switch to Llama 3.1 8B

> **Prerequisite:** HuggingFace token with Meta license approval. See [HuggingFace Secret](#huggingface-secret--llama-only) below.

1. Comment out the Qwen lines, uncomment the Llama lines:

```yaml
args:
  # --- Active model ---
  # - "Qwen/Qwen2.5-7B-Instruct"
  # - "--served-model-name=qwen2.5-7b"
  - "meta-llama/Meta-Llama-3.1-8B-Instruct"
  - "--served-model-name=llama-3.1-8b"
```

2. Uncomment the `env` block:

```yaml
env:
  - name: HUGGING_FACE_HUB_TOKEN
    valueFrom:
      secretKeyRef:
        name: hf-token
        key: token
```

3. In `k8s/llm-benchmark/01-job.yaml`, update `--model` and `--processor` to Llama values (commented alternatives are already in the file).

4. Apply:

```bash
kubectl apply -f k8s/llm-serving/01-deployment.yaml
kubectl rollout restart deploy/vllm -n llm-serving
kubectl rollout status deploy/vllm -n llm-serving --timeout=15m
```

### Switch back to Qwen 2.5 7B

Reverse the steps above (comment Llama, uncomment Qwen, comment `env` block) and apply.

---

## HuggingFace Secret

A HuggingFace token is required in two scenarios:

| Use case | Namespace | Why |
|---|---|---|
| **Llama 3.1 8B** (vLLM) | `llm-serving` | Gated model — Meta license approval required |
| **GuideLLM tokenizer** (all models) | `llm-benchmark` | Tokenizer download (~11 MB) is rate-limited to ~20 KB/s anonymously; with a token it downloads at full speed |

> **For Qwen with GuideLLM**: the token is needed only for the tokenizer, not the model itself. Qwen is ungated.

### Step 1 — Create a HuggingFace account

If you don't already have one: <https://huggingface.co/join>

### Step 2 — Accept the model license (Llama only)

1. Go to <https://huggingface.co/meta-llama/Meta-Llama-3.1-8B-Instruct>
2. Log in with your account
3. Fill in the form and click **Submit**
4. **Wait for the confirmation email from Meta** before proceeding — the download fails with `403 Forbidden` even with a valid token until the approval arrives

### Step 3 — Generate an Access Token

1. Go to <https://huggingface.co/settings/tokens>
2. Click **New token** → type **Read** → click **Generate a token**
3. **Copy the token immediately** — HuggingFace shows it only once (`hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`)

### Step 4 — Create the Kubernetes Secrets

```bash
# For vLLM (required only if using Llama)
kubectl create secret generic hf-token \
  --from-literal=token=hf_xxxxxxxxxxxxxxxxxxxx \
  --namespace llm-serving

# For GuideLLM (required for all models — tokenizer download)
kubectl create secret generic hf-token \
  --from-literal=token=hf_xxxxxxxxxxxxxxxxxxxx \
  --namespace llm-benchmark
```

Verify:

```bash
kubectl get secret hf-token -n llm-serving
kubectl get secret hf-token -n llm-benchmark
```

> `k8s/llm-serving/00-hf-secret.yaml` in this repo is a **blank template** — never commit a real token to Git.

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
- Token with **Read** access at <https://huggingface.co/settings/tokens> (required for GuideLLM tokenizer and optionally for Llama)
- Llama only: accept the Llama 3.1 license and wait for Meta approval email

---

## Step-by-Step Execution Guide

### Step 1 — Create the cluster

```bash
chmod +x infra/eks/provision.sh
./infra/eks/provision.sh

# With a named AWS profile:
./infra/eks/provision.sh --profile my-lab
```

This script (steps 1–5):
1. Creates the EKS cluster with all three node groups (`system`, `akamas`, `llm-serving`)
2. Updates kubeconfig
3. Applies the GP3 StorageClass
4. Installs the NVIDIA device plugin DaemonSet
5. Creates the three namespaces

> **Note:** the cluster region is read from `infra/eks/cluster.yaml` (hardcoded `us-east-2`). The `--region` flag only affects `eksctl get/delete` and `aws` CLI calls. To deploy in a different region, update `cluster.yaml` directly.

Expected duration: **15–25 minutes** (EKS control plane creation dominates).

Verify GPU is visible:

```bash
kubectl get nodes -L node-role
kubectl describe node -l node-role=llm-serving | grep -A8 "Allocatable"
# Must show: nvidia.com/gpu: 1
```

---

### Step 2 — HuggingFace token

```bash
# Required for GuideLLM tokenizer (all models)
kubectl create secret generic hf-token \
  --from-literal=token=hf_xxxxxxxxxxxxxxxxxxxx \
  --namespace llm-benchmark

# Required for vLLM only if using Llama — skip for Qwen (default)
kubectl create secret generic hf-token \
  --from-literal=token=hf_xxxxxxxxxxxxxxxxxxxx \
  --namespace llm-serving
```

---

### Step 3 — Deploy vLLM

```bash
kubectl apply -f k8s/llm-serving/
```

> **First boot vs subsequent boots:**
> - **First boot**: vLLM downloads the model from HuggingFace (~14 GB for Qwen, ~16 GB for Llama) and caches it on the PVC at `/root/.cache/huggingface`. This takes **5–15 minutes** depending on network speed.
> - **Subsequent restarts/patches**: model is already on the PVC — startup takes **~60 seconds** (weights load from disk into GPU VRAM).
>
> The `vllm-model-cache` PVC (25 GB) is created by `03-model-cache-pvc.yaml` and persists across pod restarts, redeployments, and node patches. To switch models, the old model files remain on the PVC (both fit within 25 GB) — vLLM will use the cached version if already present.

Watch vLLM startup (model download + load: 5–15 min on first run):

```bash
kubectl rollout status deploy/vllm -n llm-serving --timeout=15m
kubectl logs -f deploy/vllm -n llm-serving
```

Smoke-test vLLM directly:

```bash
kubectl port-forward svc/vllm 8000:8000 -n llm-serving &

# Qwen (default)
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-7b",
    "messages": [{"role": "user", "content": "Hello! Who are you?"}],
    "max_tokens": 64
  }'

# Llama (if switched)
# curl http://localhost:8000/v1/chat/completions \
#   -H "Content-Type: application/json" \
#   -d '{"model": "llama-3.1-8b", "messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 64}'
```

---

### Step 4 — Deploy Open WebUI

```bash
kubectl apply -f k8s/open-webui/
```

Wait for the pod to be ready:

```bash
kubectl rollout status deploy/open-webui -n monitoring --timeout=3m
```

Get the public IP:

```bash
kubectl get svc open-webui -n monitoring
# EXTERNAL-IP column → AWS NLB public IP / DNS name (takes 1-2 min to provision)
# Open http://<EXTERNAL-IP> in your browser
```

> The NLB exposes Open WebUI on port **80**. Open WebUI connects to vLLM internally via `http://vllm.llm-serving.svc.cluster.local:8000/v1` — no public exposure of the inference endpoint.

---

### Step 5 — Install DCGM Exporter (GPU hardware metrics)

DCGM Exporter is the NVIDIA DaemonSet that exposes GPU utilisation, VRAM, power draw and temperature to Prometheus. Without it, the three GPU panels in the dashboard show "No data".

```bash
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update

helm upgrade --install dcgm-exporter gpu-helm-charts/dcgm-exporter \
  --namespace monitoring \
  -f k8s/monitoring/dcgm-exporter-values.yaml
```

Verify the DaemonSet is running on the GPU node:

```bash
kubectl get pod -n monitoring -l app.kubernetes.io/name=dcgm-exporter
# Must show 1/1 Running on the llm-serving node
```

---

### Step 6 — Install Prometheus + Grafana

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

### Import the vLLM dashboard

A pre-built dashboard is included at `k8s/monitoring/grafana-vllm-dashboard.json`.

1. Open Grafana → **Dashboards** → **Import**
2. Click **Upload JSON file** and select `k8s/monitoring/grafana-vllm-dashboard.json`
3. Select the Prometheus datasource and click **Import**

The dashboard covers:

| Panel | Metrics |
|---|---|
| **Request Rate** (stat) | `vllm:request_success_total` |
| **Output Throughput** (stat) | `vllm:generation_tokens_total` |
| **E2E Latency p99** (stat) | `vllm:e2e_request_latency_seconds` |
| **Time to First Token p99** (stat) | `vllm:time_to_first_token_seconds` |
| **GPU KV-Cache %** (stat) | `vllm:kv_cache_usage_perc` |
| **Requests Waiting** (stat) | `vllm:num_requests_waiting` |
| **Request Latency** (timeseries) | E2E + TTFT — p50 / p95 / p99 |
| **Token Throughput** (timeseries) | Input + output tok/s |
| **Request Queue** (timeseries) | Running / waiting / swapped |
| **GPU KV-Cache Utilisation** (timeseries) | GPU + CPU KV-cache % |
| **vLLM Container CPU** (timeseries) | CPU cores used by vLLM container |
| **vLLM Container Memory** (timeseries) | Working set + RSS |
| **Inter-Token Latency** (timeseries) | TPOT — p50 / p95 / p99 |
| **GPU Utilization** (timeseries) | GPU % — requires DCGM Exporter |
| **GPU VRAM** (timeseries) | Used / total VRAM — requires DCGM Exporter |
| **GPU Power + Temperature** (timeseries) | Watts + °C — requires DCGM Exporter |

---

### Step 7 — Run the GuideLLM benchmark

```bash
kubectl apply -f k8s/llm-benchmark/00-pvc.yaml
kubectl apply -f k8s/llm-benchmark/01-job.yaml
```

The job:
1. **Init container** polls `vllm:8000/health` every 10 s until vLLM is ready (prevents race condition)
2. Downloads the Qwen tokenizer from HuggingFace using the `hf-token` secret (authenticated, fast)
3. Generates **1 000 synthetic requests** at `prompt_tokens=512, output_tokens=128` — the standard vLLM benchmark configuration
4. Runs a **throughput test**: sends requests as fast as possible to find the maximum sustainable throughput
5. Saves `benchmarks.json` to the PVC

Watch progress:

```bash
kubectl logs -f job/guidellm-benchmark -n llm-benchmark
```

> GuideLLM uses an in-place progress bar (`\r`) that does not appear in `kubectl logs`. The pod will show as `Running` silently while the benchmark executes. Verify it is actively processing by checking vLLM logs:
> ```bash
> kubectl logs -n llm-serving deployment/vllm --tail=5
> # Should show: Running: N reqs, Waiting: N reqs, GPU KV cache usage: N%
> ```

Expected duration: **5–10 minutes** (1 000 requests at max throughput on A10G).

**Benchmark dataset — synthetic `prompt_tokens=512,output_tokens=128`:**

Each request is generated as a prompt of exactly 512 tokens with an expected output of 128 tokens. This is the standard configuration used in vLLM's official `benchmark_serving.py` and the LLM Perf Leaderboard — results are directly comparable with published numbers. The tokenizer (`--processor Qwen/Qwen2.5-7B-Instruct`) ensures accurate token counting.

---

### Step 8 — Retrieve benchmark results

GuideLLM saves results as JSON only (`benchmarks.json`). Use `kubectl cp` to download from the PVC:

```bash
# 1. Create a temporary pod with the PVC mounted
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: results-reader
  namespace: llm-benchmark
spec:
  restartPolicy: Never
  nodeSelector:
    node-role: system
  containers:
    - name: reader
      image: alpine:3
      command: ["sleep", "300"]
      volumeMounts:
        - name: results
          mountPath: /benchmarks
  volumes:
    - name: results
      persistentVolumeClaim:
        claimName: guidellm-results
EOF

kubectl wait pod/results-reader -n llm-benchmark --for=condition=Ready --timeout=60s

# 2. Copy the results locally
kubectl cp llm-benchmark/results-reader:/benchmarks/benchmarks.json ./benchmarks.json

# 3. Clean up
kubectl delete pod results-reader -n llm-benchmark
```

View results:

```bash
# Pretty-print key metrics
cat benchmarks.json | python3 -m json.tool | head -100

# Or open in VS Code
code benchmarks.json
```

---

## Architectural Decisions

### Why separate `system` and `llm-serving` node groups?

**Cost and isolation.** GPU instances (`g5.2xlarge`, ~$1.21/h) cost 6× more than CPU instances (`m6i.xlarge`, ~$0.19/h). Separating them allows:
- **Cost control**: delete the GPU node group between benchmarks, keep the monitoring/UI stack alive at $0.30/h
- **Noisy-neighbour prevention**: without the taint, Prometheus or GuideLLM could land on the GPU node and steal CPU/memory from vLLM's tokenisation threads
- **Scheduling determinism**: the taint + toleration + nodeSelector combination guarantees that only vLLM (and the device plugin) ever runs on the GPU node

### Why Qwen 2.5 7B as the default instead of Llama 3.1 8B?

**No approval gate.** Qwen 2.5 7B Instruct is fully open (Apache 2.0) and downloads immediately — no HuggingFace license form, no Meta approval email to wait for. Benchmark quality is comparable to Llama 3.1 8B on most instruction-following tasks, and the smaller weight footprint (~14 GB vs ~16 GB) leaves ~2 GB of extra KV-cache headroom. Llama remains available in the deployment as a commented-out alternative for teams that already have approval.

### Why `operator: Exists` in the GPU toleration?

Using `operator: Equal` (the default when `operator` is omitted) requires the toleration `value` to exactly match the taint value on the node. If the taint is ever updated — or if `eksctl` sets a slightly different value — the pod silently stays in `Pending`. `operator: Exists` matches any taint with the given key and effect, regardless of value, and is the pattern used by the NVIDIA device plugin itself.

### Why a PVC for GuideLLM output?

Kubernetes Jobs are ephemeral — without a PVC the `benchmarks.json` file disappears when the pod terminates. With a `Retain` GP3 PVC, results survive restarts and cluster operations. To accumulate results across runs, parameterize `--output-path /benchmarks/<run-id>` in the Job spec.

### Why `--gpu-memory-utilization=0.90` instead of 1.0?

Setting utilization to 1.0 leaves no headroom for CUDA library overhead (~200–400 MB), runtime memory fragmentation, and BF16 weight padding. 0.90 is the vLLM default and is safe. You can raise it to 0.95 for throughput experiments, but OOM kills become more likely.

### Why synthetic `prompt_tokens=512,output_tokens=128` for the benchmark?

This is the standard configuration used in vLLM's official `benchmark_serving.py` and the LLM Perf Leaderboard — results are directly comparable with published numbers across models and hardware. Synthetic data also avoids HuggingFace dataset download issues (schema incompatibilities, rate limits) and produces reproducible, deterministic results across runs. The tokenizer (`--processor`) ensures token counts are accurate even with synthetic inputs.

For production-realism benchmarking (variable length, multi-turn), consider ShareGPT-style datasets — but note that GuideLLM's HF dataset loading requires a dataset with a flat text column (not the conversation-list format used by `lmsys/chatbot_arena_conversations`).

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

A full benchmark run takes ~10 minutes: **~$0.30 per run**. Delete the GPU node group when not actively benchmarking.

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
# Qwen:  no auth needed — check VRAM / OOM errors
# Llama: 401/403 from HuggingFace → invalid or missing hf-token secret
# Both:  OOM → reduce --max-model-len or increase --gpu-memory-utilization carefully
```

**`ValueError: VLLM_PORT appears to be a URI`**

Kubernetes injects a `VLLM_PORT=tcp://<clusterIP>:8000` env var (service discovery) that conflicts with vLLM's own `VLLM_PORT` variable. Fix: ensure `enableServiceLinks: false` is set in the pod spec (`k8s/llm-serving/01-deployment.yaml`).

```bash
kubectl get deploy vllm -n llm-serving -o jsonpath='{.spec.template.spec.enableServiceLinks}'
# Must return: false
```

**Open WebUI shows no models**

The UI reads available models from `GET /v1/models`. If the list is empty, vLLM is not reachable:
```bash
kubectl exec -it deploy/open-webui -n monitoring -- \
  curl -s http://vllm.llm-serving.svc.cluster.local:8000/v1/models
```

**Prometheus not scraping vLLM**

```bash
kubectl get servicemonitor -n monitoring
# Verify serviceMonitorSelectorNilUsesHelmValues: false is set in Helm values
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
# http://localhost:9090/targets → look for errors on llm-serving/vllm
```

**GuideLLM job fails with `PermissionError: /benchmarks/benchmarks.json`**

The GuideLLM container runs as non-root and cannot write to the PVC by default. The job spec includes `securityContext: { fsGroup: 0, runAsUser: 0 }` to fix this. If you see the error, verify the security context is present:

```bash
kubectl get job guidellm-benchmark -n llm-benchmark \
  -o jsonpath='{.spec.template.spec.securityContext}'
# Must return: {"fsGroup":0,"runAsUser":0}
```

**GuideLLM tokenizer download hangs (10+ minutes)**

Anonymous HuggingFace downloads are rate-limited to ~20 KB/s. The tokenizer (`tokenizer.json`) is ~11 MB — at 20 KB/s it takes over 9 minutes. Fix: ensure the `hf-token` secret exists in the `llm-benchmark` namespace and the `HUGGING_FACE_HUB_TOKEN` env var is set in the job spec.

```bash
kubectl get secret hf-token -n llm-benchmark
# If missing: kubectl create secret generic hf-token --from-literal=token=hf_xxx --namespace llm-benchmark
```

---

## Stop GPU Billing (Keep Cluster Alive)

```bash
eksctl delete nodegroup \
  --cluster vllm-bench \
  --region us-east-2 \
  --name llm-serving \
  --approve

# Re-add GPU node before next benchmark run:
eksctl create nodegroup -f infra/eks/nodegroups.yaml
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml
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
│       └── provision.sh                   # One-shot provisioning script (--profile, --region)
└── k8s/
    ├── 00-namespaces.yaml                 # llm-serving, llm-benchmark, monitoring
    ├── llm-serving/
    │   ├── 00-hf-secret.yaml             # HuggingFace token secret (template — do not commit token)
    │   ├── 01-deployment.yaml            # vLLM (GPU, taint toleration, enableServiceLinks: false, Recreate strategy)
    │   ├── 02-service.yaml               # ClusterIP on :8000
    │   └── 03-model-cache-pvc.yaml       # 25 GB PVC for HF model cache — eliminates re-download on restart
    ├── open-webui/
    │   ├── 00-pvc.yaml                   # 5 GB PVC for chat history + settings  (namespace: monitoring)
    │   ├── 01-deployment.yaml            # Open WebUI (CPU node, connects to vLLM via FQDN)  (namespace: monitoring)
    │   └── 02-service.yaml               # LoadBalancer (NLB) on :80 → public IP  (namespace: monitoring)
    ├── llm-benchmark/
    │   ├── 00-pvc.yaml                   # 10 GB PVC for benchmark results
    │   └── 01-job.yaml                   # GuideLLM throughput Job (synthetic ISL=512/OSL=128, hf-token for tokenizer)
    └── monitoring/
        ├── values-kube-prometheus.yaml   # Helm values (node pinning, GP3 storage, cross-NS scraping)
        ├── dcgm-exporter-values.yaml     # Helm values for NVIDIA DCGM Exporter (GPU hardware metrics)
        ├── servicemonitor.yaml           # Scrape vLLM /metrics every 15 s
        └── grafana-vllm-dashboard.json   # Pre-built Grafana dashboard (vLLM + GPU + container resources)
```
