#!/usr/bin/env bash
# Usage:
#   VLLM_BATCH_SIZE=128 ./run.sh
#   VLLM_MAX_SEQS=64 VLLM_MAX_TOKENS=4096 VLLM_GPU_MEMORY_UTIL=0.90 ./run.sh
set -euo pipefail

MANIFEST_FILE="${VLLM_MANIFEST_FILE:-../llm-serving/01-deployment.yaml}"
NAMESPACE="${VLLM_NAMESPACE:-llm-serving}"

[[ -f "$MANIFEST_FILE" ]] || { echo "Manifest not found: $MANIFEST_FILE"; exit 1; }

tmpfile="$(mktemp vllm-XXXXXX.yaml)"
cp "$MANIFEST_FILE" "$tmpfile"

# For each parameter: if the env var is set, replace the value in-place;
# if it is unset, remove the entire arg line so vLLM uses its built-in default.
if [[ -n "${VLLM_MAX_SEQS:-}" ]]; then
  sed -i "s/\(--max-num-seqs=\)[0-9]\+/\1${VLLM_MAX_SEQS}/g" "$tmpfile"
else
  sed -i "/--max-num-seqs=/d" "$tmpfile"
fi

if [[ -n "${VLLM_MAX_TOKENS:-}" ]]; then
  sed -i "s/\(--max-num-batched-tokens=\)[0-9]\+/\1${VLLM_MAX_TOKENS}/g" "$tmpfile"
else
  sed -i "/--max-num-batched-tokens=/d" "$tmpfile"
fi

if [[ -n "${VLLM_GPU_MEMORY_UTIL:-}" ]]; then
  sed -i "s/\(--gpu-memory-utilization=\)[0-9.]\+/\1${VLLM_GPU_MEMORY_UTIL}/g" "$tmpfile"
else
  sed -i "/--gpu-memory-utilization=/d" "$tmpfile"
fi

if [[ -n "${VLLM_MAX_MODEL:-}" ]]; then
  sed -i "s/\(--max-model-len=\)[0-9]\+/\1${VLLM_MAX_MODEL}/g" "$tmpfile"
else
  sed -i "/--max-model-len=/d" "$tmpfile"
fi

if [[ -n "${VLLM_BLOCK_SIZE:-}" ]]; then
  [[ "$VLLM_BLOCK_SIZE" =~ ^(8|16|32)$ ]] || { echo "VLLM_BLOCK_SIZE must be 8, 16, or 32"; exit 1; }
  sed -i "s/\(--block-size=\)[0-9]\+/\1${VLLM_BLOCK_SIZE}/g" "$tmpfile"
else
  sed -i "/--block-size=/d" "$tmpfile"
fi

if [[ -n "${VLLM_ATTENTION_BACKEND:-}" ]]; then
  [[ "$VLLM_ATTENTION_BACKEND" =~ ^(FLASH_ATTN|FLASHINFER|XFORMERS|TORCH_SDPA|FLASHMLA|ROCM_FLASH)$ ]] \
    || { echo "VLLM_ATTENTION_BACKEND must be one of: FLASH_ATTN, FLASHINFER, XFORMERS, TORCH_SDPA, FLASHMLA, ROCM_FLASH"; exit 1; }
  # Insert before the --dtype line (or any stable anchor) since the arg may not pre-exist in the YAML
  sed -i "/- \"--dtype=/i\\            - \"--attention-config.backend=${VLLM_ATTENTION_BACKEND}\"" "$tmpfile"
else
  sed -i "/--attention-config.backend=/d" "$tmpfile"
fi

kubectl apply -f "$tmpfile" -n "$NAMESPACE"
rm -f "$tmpfile"

./bench_ramp.sh

sleep 60
