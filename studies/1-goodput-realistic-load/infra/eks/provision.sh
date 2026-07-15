#!/usr/bin/env bash
set -euo pipefail

# Provision the vllm-bench EKS cluster for this study (1-goodput-realistic-load).
#
# Node layout (all defined in cluster.yaml, created in one shot):
#   system      (m6i.xlarge,  4 vCPU / 16 GB)               — Prometheus, Grafana, inference-perf
#   akamas      (r6i.xlarge,  4 vCPU / 32 GB)               — Akamas (optional)
#   llm-serving (g5.2xlarge,  8 vCPU / 32 GB / 1× A10G)     — vLLM only (tainted, AmazonLinux2023)
#
# This is this study's own copy of the infra layer (per this repo's atomic-per-study
# convention), but it deliberately targets the SAME cluster name/config as
# studies/0-explorative — this study reuses that already-provisioned A10G hardware on
# purpose (validate the new load-testing tool and pack version before also changing
# hardware). If that cluster is already up, this script detects it and skips creation.
#
# This script is otherwise this study's own copy of the infra layer — deliberately not
# shared with other studies, so this study stays reproducible on its own even if a
# future study's cluster.yaml (e.g. a different instance type or node group layout)
# diverges.
#
# After the cluster is up, the NVIDIA device plugin DaemonSet is installed so that
# Kubernetes can see nvidia.com/gpu as an allocatable resource.
#
# Usage:
#   ./provision.sh
#   ./provision.sh --region us-west-2
#   ./provision.sh --profile my-aws-profile

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STUDY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLUSTER_CONFIG="$SCRIPT_DIR/cluster.yaml"
STORAGE_CLASS="$SCRIPT_DIR/storageclass.yaml"
BOOTSTRAP_DIR="$STUDY_ROOT/infra/k8s-bootstrap"
K8S_DIR="$STUDY_ROOT/k8s"

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
echo "=== vllm-bench EKS Cluster (studies/1-goodput-realistic-load) ==="
echo "Cluster : $CLUSTER_NAME"
echo "Region  : $AWS_REGION"
echo ""

# --- 1. Create cluster (all node groups defined in cluster.yaml) ---
# NOTE: when using -f, eksctl reads region from cluster.yaml (us-east-2).
# The --region flag of this script only affects eksctl get/delete and aws cli calls.
# To deploy in a different region, update cluster.yaml directly.
echo "[1/6] Cluster + node groups..."
if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" $PROFILE_ARG >/dev/null 2>&1; then
  echo "  Cluster '$CLUSTER_NAME' already exists — skipping creation."
else
  eksctl create cluster -f "$CLUSTER_CONFIG" $PROFILE_ARG
  echo "  Cluster created."
fi

# --- 2. Update kubeconfig ---
echo ""
echo "[2/6] Updating kubeconfig..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" $PROFILE_ARG
echo "  Context: $(kubectl config current-context)"

# --- 3. StorageClasses ---
# gp3 (this folder): default class, Retain reclaim policy — Prometheus/Grafana/Akamas
# volumes and anything that should survive an accidental PVC delete.
# gp3-ephemeral (infra/k8s-bootstrap): Delete reclaim policy — used for the
# re-downloadable model-cache PVC, so tearing it down doesn't leave an orphaned volume.
echo ""
echo "[3/6] Applying StorageClasses (gp3 default + gp3-ephemeral)..."
kubectl apply -f "$STORAGE_CLASS"
kubectl apply -f "$BOOTSTRAP_DIR/01-storage-classes.yaml"

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
echo "[4/6] Installing NVIDIA device plugin..."
kubectl apply -f \
  https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml
echo "  Waiting for DaemonSet rollout on GPU node (up to 3 min)..."
kubectl rollout status daemonset/nvidia-device-plugin-daemonset \
  --namespace kube-system \
  --timeout=180s

# --- 5. Namespaces ---
echo ""
echo "[5/6] Applying Kubernetes namespaces (llm-serving, llm-benchmark, monitoring)..."
kubectl apply -f "$BOOTSTRAP_DIR/00-namespaces.yaml"

# --- 6. PVCs (one-time, persist across the whole study — not managed by any workflow task) ---
echo ""
echo "[6/6] Applying this study's PVCs..."
kubectl apply -f "$K8S_DIR/00-pvc.yaml"
kubectl apply -f "$K8S_DIR/01-pvc-model-cache.yaml"

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
echo "Next steps (still manual, not run by this script):"
echo ""
echo "  1. Install NVIDIA DCGM Exporter (GPU hardware metrics):"
echo "       helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts"
echo "       helm repo update"
echo "       kubectl create configmap dcgm-custom-metrics \\"
echo "         --from-file=metrics=$K8S_DIR/monitoring/dcgm_counters.csv -n monitoring"
echo "       helm upgrade --install dcgm-exporter gpu-helm-charts/dcgm-exporter \\"
echo "         --namespace monitoring \\"
echo "         -f $K8S_DIR/monitoring/dcgm-exporter-values.yaml"
echo ""
echo "  2. Install Prometheus + Grafana:"
echo "       helm repo add prometheus-community https://prometheus-community.github.io/helm-charts"
echo "       helm repo update"
echo "       helm upgrade --install kube-prometheus-stack \\"
echo "         prometheus-community/kube-prometheus-stack \\"
echo "         --namespace monitoring \\"
echo "         -f $K8S_DIR/monitoring/values-kube-prometheus.yaml"
echo "       kubectl apply -f $K8S_DIR/monitoring/servicemonitor.yaml"
echo ""
echo "  3. (Optional) import the Grafana dashboards:"
echo "       kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
echo "       open http://localhost:3000  # admin / changeme"
echo "       Dashboards → Import → Upload: $K8S_DIR/monitoring/vllm-performance-dashboard.json"
echo "       Dashboards → Import → Upload: $K8S_DIR/monitoring/grafana-vllm-dashboard.json"
echo ""
echo "  4. Deploy vLLM manually to sanity-check the stack before creating the Akamas"
echo "     study (Akamas' own workflow renders and applies this on each trial —"
echo "     this manual step is only to confirm the cluster/image/model actually work):"
echo "       kubectl apply -f $K8S_DIR/02-service.yaml"
echo "       # render \${vLLM.*} tokens in 01-deployment_template.yaml by hand or via"
echo "       # the akamas-study-manager's FileConfigurator once the study exists"
echo ""
echo "     If serving a gated model (e.g. Llama 3.1) instead of the default"
echo "     Qwen2.5-7B-Instruct, create the HuggingFace token secret first:"
echo "       kubectl create secret generic hf-token \\"
echo "         --from-literal=token=<YOUR_HF_TOKEN> \\"
echo "         --namespace llm-serving"
echo "     (see $K8S_DIR/03-hf-secret.yaml for the template)"
echo ""
echo "  5. Create and start the Akamas study — see this study's own README.md"
echo "     ('How to run') for the exact akamas create/start commands."
echo ""
echo "Stop GPU billing (keep cluster running):"
echo "  eksctl delete nodegroup --cluster $CLUSTER_NAME --region $AWS_REGION --name llm-serving --approve $PROFILE_ARG"
echo ""
echo "Full teardown:"
echo "  eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION $PROFILE_ARG"
