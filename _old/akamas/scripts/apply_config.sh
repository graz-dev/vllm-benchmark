kubectl apply -f /work/vllm-benchmark/akamas/templates/01-deployment.yaml -n llm-serving
kubectl rollout status deployment/vllm -n llm-serving --timeout=1200s