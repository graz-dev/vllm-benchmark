#!/usr/bin/env bash
set -euo pipefail

# Provision the vllm-bench EKS cluster.
#
# Node layout (all defined in cluster.yaml, created in one shot):
#   system      (m6i.xlarge,  4 vCPU / 16 GB)               — Prometheus, Grafana, Open WebUI, GuideLLM
#   akamas      (r6i.xlarge,  4 vCPU / 32 GB)               — Akamas (optional)
#   llm-serving (g5.2xlarge,  8 vCPU / 32 GB / 1× A10G)     — vLLM only (tainted, AmazonLinux2023)
#
# After the cluster is up, the NVIDIA device plugin DaemonSet is installed
# so that Kubernetes can see nvidia.com/gpu as an allocatable resource.
#
# Usage:
#   ./provision.sh
#   ./provision.sh --region us-west-2
#   ./provision.sh --profile my-aws-profile

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLUSTER_CONFIG="$SCRIPT_DIR/cluster.yaml"
STORAGE_CLASS="$SCRIPT_DIR/storageclass.yaml"
K8S_DIR="$REPO_ROOT/k8s"

CLUSTER_NAME="vllm-bench"
AWS_REGION="us-east-2"
AWS_PROFILE=""

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --region)   AWS_REGION="$2"; shift 2 ;;
    --profile)  AWS_PROFILE="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--region <region>] [--profile <profile>]"
      exit 0
      ;;
    *) echo "Unknown argument: $1. Run $0 --help for usage."; exit 1 ;;
  esac
done

# --- Prerequisites ---
for cmd in eksctl kubectl aws helm; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found in PATH"; exit 1; }
done

PROFILE_ARG=""
if [[ -n "$AWS_PROFILE" ]]; then
  PROFILE_ARG="--profile $AWS_PROFILE"
  CALLER=$(aws sts get-caller-identity $PROFILE_ARG --query 'Arn' --output text)
  echo "AWS profile : $AWS_PROFILE"
  echo "Identity    : $CALLER"
fi

echo ""
echo "=== vllm-bench EKS Cluster ==="
echo "Cluster : $CLUSTER_NAME"
echo "Region  : $AWS_REGION"
echo ""

# --- 1. Create cluster (all node groups defined in cluster.yaml) ---
# NOTE: when using -f, eksctl reads region from cluster.yaml (us-east-2).
# The --region flag of this script only affects eksctl get/delete and aws cli calls.
# To deploy in a different region, update cluster.yaml directly.
echo "[1/5] Cluster + node groups..."
if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" $PROFILE_ARG >/dev/null 2>&1; then
  echo "  Cluster '$CLUSTER_NAME' already exists — skipping creation."
else
  eksctl create cluster -f "$CLUSTER_CONFIG" $PROFILE_ARG
  echo "  Cluster created."
fi

# --- 2. Update kubeconfig ---
echo ""
echo "[2/5] Updating kubeconfig..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" $PROFILE_ARG
echo "  Context: $(kubectl config current-context)"

# --- 3. StorageClass ---
echo ""
echo "[3/5] Applying GP3 StorageClass..."
kubectl apply -f "$STORAGE_CLASS"

# --- 4. NVIDIA device plugin ---
# The EKS accelerated AMI (amiFamily: AmazonLinux2023 on GPU instance) ships with
# NVIDIA drivers in the OS — but Kubernetes does not know about the GPU until
# the device plugin DaemonSet is running and advertising nvidia.com/gpu resources.
#
# The standard DaemonSet already has:
#   tolerations:
#     - key: nvidia.com/gpu
#       operator: Exists
#       effect: NoSchedule
# so it will schedule on the tainted llm-serving node without any extra config.
echo ""
echo "[4/5] Installing NVIDIA device plugin..."
kubectl apply -f \
  https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml
echo "  Waiting for DaemonSet rollout on GPU node (up to 3 min)..."
kubectl rollout status daemonset/nvidia-device-plugin-daemonset \
  --namespace kube-system \
  --timeout=180s

# --- 5. Namespaces ---
echo ""
echo "[5/5] Applying Kubernetes namespaces..."
kubectl apply -f "$K8S_DIR/00-namespaces.yaml"

# --- Summary ---
echo ""
echo "=== Done ==="
echo ""
kubectl get nodes -L node-role
echo ""
echo "Verify GPU is visible to Kubernetes:"
echo "  kubectl describe node -l node-role=llm-serving | grep -A5 Allocatable"
echo "  # Should show: nvidia.com/gpu: 1"
echo ""
echo "Next steps:"
echo ""
echo "  1. Deploy vLLM (default model: Qwen2.5-7B-Instruct — no token required):"
echo "       kubectl apply -f $K8S_DIR/llm-serving/"
echo "       kubectl rollout status deploy/vllm -n llm-serving --timeout=15m"
echo ""
echo "     To use Llama 3.1 8B instead, first create the HuggingFace token secret:"
echo "       kubectl create secret generic hf-token \\"
echo "         --from-literal=token=<YOUR_HF_TOKEN> \\"
echo "         --namespace llm-serving"
echo "     Then edit k8s/llm-serving/01-deployment.yaml to switch the active model."
echo ""
echo "  2. Deploy Open WebUI (namespace: monitoring, exposed via NLB):"
echo "       kubectl apply -f $K8S_DIR/open-webui/"
echo "       kubectl get svc open-webui -n monitoring  # EXTERNAL-IP = public URL"
echo ""
echo "  3. Install NVIDIA DCGM Exporter (GPU hardware metrics):"
echo "       helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts"
echo "       helm repo update"
echo "       helm upgrade --install dcgm-exporter gpu-helm-charts/dcgm-exporter \\"
echo "         --namespace monitoring \\"
echo "         -f $K8S_DIR/monitoring/dcgm-exporter-values.yaml"
echo ""
echo "  4. Install Prometheus + Grafana:"
echo "       helm repo add prometheus-community https://prometheus-community.github.io/helm-charts"
echo "       helm repo update"
echo "       helm upgrade --install kube-prometheus-stack \\"
echo "         prometheus-community/kube-prometheus-stack \\"
echo "         --namespace monitoring --create-namespace \\"
echo "         -f $K8S_DIR/monitoring/values-kube-prometheus.yaml"
echo "       kubectl apply -f $K8S_DIR/monitoring/servicemonitor.yaml"
echo ""
echo "  5. Import the Grafana dashboard:"
echo "       kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
echo "       open http://localhost:3000  # admin / changeme"
echo "       Dashboards → Import → Upload: $K8S_DIR/monitoring/grafana-vllm-dashboard.json"
echo ""
echo "  6. Run GuideLLM benchmark:"
echo "       kubectl apply -f $K8S_DIR/llm-benchmark/"
echo "       kubectl logs -f job/guidellm-benchmark -n llm-benchmark"
echo ""
echo "Stop GPU billing (keep cluster running):"
echo "  eksctl delete nodegroup --cluster $CLUSTER_NAME --region $AWS_REGION --name llm-serving --approve $PROFILE_ARG"
echo ""
echo "Full teardown:"
echo "  eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION $PROFILE_ARG"
