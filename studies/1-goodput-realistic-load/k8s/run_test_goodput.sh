#!/bin/bash

BENCH_FILE=/work/vllm-benchmark/studies/1-goodput-realistic-load/k8s/05-job.yaml
CONFIG_FILE=/work/vllm-benchmark/studies/1-goodput-realistic-load/k8s/04-inference-perf-config.yaml

# The ConfigMap is static across trials (same load pattern/dataset every time — only
# the vLLM deployment being benchmarked changes), but re-apply it each run so a manual
# edit to 04-inference-perf-config.yaml always takes effect on the next trial.
kubectl apply -f "$CONFIG_FILE"

kubectl delete -f "$BENCH_FILE" ; kubectl apply -f "$BENCH_FILE"

# Same rationale as apply_config.sh's vLLM log dump: don't exit immediately on a failed
# wait — print the job's own container logs first, so they land in this task's stdout
# and show up in the Akamas UI without needing separate kubectl access.
#
# --timeout=6000s (100m), not the original 1200s (20m): confirmed 2026-07-16 from a
# real trial that individual sweep stages take far longer than their nominal 60s once
# the rate approaches saturation (stage durations observed growing from ~63s to
# ~200s+ well before the highest rates) — a trial nearing the top of the ramp can
# easily exceed 1200s total even though the Job itself is healthy and still running,
# which would fail the trial on this script's own timeout rather than a real problem.
# 6000s stays safely under the workflow's own RunTest task timeout (120m = 7200s, see
# akamas/1-Goodput-Realistic-Load-Workflow.yaml), leaving headroom for this wait plus
# the log-dumping below.
set +e
kubectl wait --for=condition=complete job/inference-perf-benchmark -n llm-benchmark --timeout=6000s
WAIT_EXIT=$?
set -e

echo "--- wait-for-vllm init container logs ---"
kubectl logs job/inference-perf-benchmark -n llm-benchmark -c wait-for-vllm --tail=200 || true
echo "--- inference-perf container logs ---"
kubectl logs job/inference-perf-benchmark -n llm-benchmark -c inference-perf --tail=500 || true

exit $WAIT_EXIT
