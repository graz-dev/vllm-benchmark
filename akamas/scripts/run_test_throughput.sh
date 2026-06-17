#!/bin/bash

BENCH_FILE=/work/vllm-benchmark/k8s/llm-benchmark/01-job.yaml

kubectl delete -f $BENCH_FILE ; kubectl apply -f $BENCH_FILE
kubectl wait --for=condition=complete job/guidellm-benchmark -n llm-benchmark --timeout=1000s