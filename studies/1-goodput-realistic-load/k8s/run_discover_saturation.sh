#!/bin/bash

DISCOVER_FILE=/work/vllm-benchmark/studies/1-goodput-realistic-load/k8s/07-discover-job.yaml

kubectl delete -f "$DISCOVER_FILE" ; kubectl apply -f "$DISCOVER_FILE"

# 8 grid steps x 300s = 40 min expected; --timeout=3000s (50m) gives margin,
# still safely under the workflow's own Discover task timeout (60m, see
# akamas/1-Goodput-Realistic-Load-Workflow.yaml).
set +e
kubectl wait --for=condition=complete job/aiperf-discover -n llm-benchmark --timeout=3000s
WAIT_EXIT=$?
set -e

echo "--- wait-for-vllm init container logs ---"
kubectl logs job/aiperf-discover -n llm-benchmark -c wait-for-vllm --tail=200 || true
echo "--- aiperf container logs ---"
kubectl logs job/aiperf-discover -n llm-benchmark -c aiperf --tail=500 || true

exit $WAIT_EXIT
