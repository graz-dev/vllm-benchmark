#!/bin/bash

BENCH_FILE=/work/vllm-benchmark/studies/0-explorative/k8s/01-job.yaml

kubectl delete -f $BENCH_FILE ; kubectl apply -f $BENCH_FILE

# Same rationale as apply_config.sh's vLLM log dump: don't exit immediately on a failed
# wait — print the job's own container logs first, so they land in this task's stdout
# and show up in the Akamas UI without needing separate kubectl access.
set +e
kubectl wait --for=condition=complete job/guidellm-benchmark -n llm-benchmark --timeout=1000s
WAIT_EXIT=$?
set -e

echo "--- wait-for-vllm init container logs ---"
kubectl logs job/guidellm-benchmark -n llm-benchmark -c wait-for-vllm --tail=200 || true
echo "--- guidellm container logs ---"
kubectl logs job/guidellm-benchmark -n llm-benchmark -c guidellm --tail=200 || true

exit $WAIT_EXIT
