#!/bin/bash

BENCH_FILE=/work/vllm-benchmark/studies/1-goodput-realistic-load/k8s/05-job.yaml

# No ConfigMap to apply separately (2026-07-17, AIPerf swap) — the load pattern is
# just CLI flags on the Job's own command, so re-applying the Job manifest each run
# is enough for a manual edit to 05-job.yaml to take effect on the next trial.
kubectl delete -f "$BENCH_FILE" ; kubectl apply -f "$BENCH_FILE"

# Same rationale as apply_config.sh's vLLM log dump: don't exit immediately on a failed
# wait — print the job's own container logs first, so they land in this task's stdout
# and show up in the Akamas UI without needing separate kubectl access.
#
# 2026-07-21: the "Discover" task (run_discover_saturation.sh) now runs before this
# one each trial and already ensures the dataset cache exists, so this job no longer
# has a prep step — expected total is just 6 x 300s levels (~30min) plus a few
# seconds of overhead. --timeout=2100s (35m) replaces the old 6000s inference-perf-era
# value, still with margin, and safely under the workflow's own RunTest task timeout
# (60m, see akamas/1-Goodput-Realistic-Load-Workflow.yaml).
set +e
kubectl wait --for=condition=complete job/aiperf-benchmark -n llm-benchmark --timeout=2100s
WAIT_EXIT=$?
set -e

echo "--- wait-for-vllm init container logs ---"
kubectl logs job/aiperf-benchmark -n llm-benchmark -c wait-for-vllm --tail=200 || true
echo "--- aiperf container logs ---"
kubectl logs job/aiperf-benchmark -n llm-benchmark -c aiperf --tail=500 || true

exit $WAIT_EXIT
