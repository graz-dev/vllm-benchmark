#!/usr/bin/env bash
# Usage:
#   VLLM_BATCH_SIZE=128 ./run.sh
#   VLLM_BATCH_SIZE=64 VLLM_MAX_TOKENS=4096 VLLM_GPU_MEMORY_UTIL=0.90 ./run.sh
set -euo pipefail

MANIFEST_FILE="${VLLM_MANIFEST_FILE:-../llm-serving/01-deployment.yaml}"
NAMESPACE="${VLLM_NAMESPACE:-llm-serving}"

[[ -f "$MANIFEST_FILE" ]] || { echo "Manifest not found: $MANIFEST_FILE"; exit 1; }

tmpfile="$(mktemp vllm-XXXXXX.yaml)"
cp "$MANIFEST_FILE" "$tmpfile"

[[ -n "${VLLM_MAX_SEQS:-}"      ]] && sed -i "s/\(--max-num-seqs=\)[0-9]\+/\1${VLLM_MAX_SEQS}/g"              "$tmpfile"
[[ -n "${VLLM_MAX_TOKENS:-}"      ]] && sed -i "s/\(--max-num-batched-tokens=\)[0-9]\+/\1${VLLM_MAX_TOKENS}/g"             "$tmpfile"
[[ -n "${VLLM_GPU_MEMORY_UTIL:-}" ]] && sed -i "s/\(--gpu-memory-utilization=\)[0-9.]\+/\1${VLLM_GPU_MEMORY_UTIL}/g" "$tmpfile"
#[[ -n "${VLLM_MAX_MODEL:-}" ]] && sed -i "s/\(--max-model-len=\)[0-9.]\+/\1${VLLM_MAX_MODEL}/g" "$tmpfile"

#exit

kubectl apply -f "$tmpfile" -n "$NAMESPACE"
rm -f "$tmpfile"

BENCH_FILE="${BENCH_FILE:-01-job-concurrent-sweep.yaml}"
kubectl delete -f ${BENCH_FILE} ; kubectl apply -f ${BENCH_FILE}
kubectl wait --for=condition=complete job/guidellm-benchmark -n llm-benchmark --timeout=3600s
kubectl logs job/guidellm-benchmark -n llm-benchmark > "guidellm_${VLLM_MAX_SEQS}_${VLLM_MAX_TOKENS}_${VLLM_GPU_MEMORY_UTIL}_$(date -Is).logs"

sleep 60
