#!/bin/bash

BENCH_FILE=/work/vllm-benchmark/studies/4-goodput-extended/k8s/05-job.yaml

# No ConfigMap to apply separately — the load pattern is just CLI flags on the Job's
# own command, so re-applying the Job manifest each run is enough for a manual edit
# to 05-job.yaml (e.g. a recalibrated concurrency list) to take effect on the next trial.
kubectl delete -f "$BENCH_FILE" ; kubectl apply -f "$BENCH_FILE"

# Same rationale as apply_config.sh's vLLM log dump: don't exit immediately on a failed
# wait — print the job's own container logs first, so they land in this task's stdout
# and show up in the Akamas UI without needing separate kubectl access.
#
# --timeout=9300s (155m), raised 2026-09-04 for this study's extended 24-level
# concurrency sweep (double 2-larger-model-g7e's own 12 levels, up to 2048): up to
# 900s (15min) one-time dataset-prep on a cold cache + 24 x 300s levels (120min) +
# ~20min buffer for pip-install/per-level dataset-file generation/misc overhead =
# worst case comfortably under 155m. Was 5700s (95m) for the 12-level sweep.
set +e
kubectl wait --for=condition=complete job/aiperf-benchmark -n llm-benchmark --timeout=9300s
WAIT_EXIT=$?
set -e

echo "--- wait-for-vllm init container logs ---"
kubectl logs job/aiperf-benchmark -n llm-benchmark -c wait-for-vllm --tail=200 || true
echo "--- aiperf container logs ---"
kubectl logs job/aiperf-benchmark -n llm-benchmark -c aiperf --tail=500 || true

exit $WAIT_EXIT
