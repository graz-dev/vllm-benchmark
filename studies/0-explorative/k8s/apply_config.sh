DEPLOY_FILE=/work/vllm-benchmark/studies/0-explorative/k8s/01-deployment.yaml

# vLLM's boolean flags (enforce-eager, disable-cascade-attn, async-scheduling,
# enable-expert-parallel, disable-custom-all-reduce) use argparse.BooleanOptionalAction,
# which rejects an explicit "--flag=value" form (confirmed: it raises "ignored explicit
# argument" for any --flag=... call) — only bare --flag / --no-flag is accepted. The
# Akamas vLLM pack declares these as categorical "true"/"false" string parameters, so
# FileConfigurator renders "--flag=true"/"--flag=false" into the deployment args; rewrite
# those into the accepted form here, right before applying.
for flag in enforce-eager disable-cascade-attn async-scheduling enable-expert-parallel disable-custom-all-reduce; do
  sed -i "s/--${flag}=true/--${flag}/" "$DEPLOY_FILE"
  sed -i "s/--${flag}=false/--no-${flag}/" "$DEPLOY_FILE"
done

kubectl apply -f "$DEPLOY_FILE" -n llm-serving

# Don't let a failed rollout exit immediately — print vLLM's own container logs first,
# so they land in this task's stdout and show up in the Akamas UI (experiment/trial
# view) without needing separate kubectl access. This is exactly the log that would
# have shown the "Concurrent Partial Prefill" NotImplementedError directly in Akamas.
set +e
kubectl rollout status deployment/vllm -n llm-serving --timeout=1200s
ROLLOUT_EXIT=$?
set -e

echo "--- vLLM container logs (current pod) ---"
kubectl logs deployment/vllm -n llm-serving --tail=200 || true
echo "--- vLLM container logs (previous pod, if it crashed and restarted) ---"
kubectl logs deployment/vllm -n llm-serving --tail=200 --previous 2>/dev/null || true

exit $ROLLOUT_EXIT
