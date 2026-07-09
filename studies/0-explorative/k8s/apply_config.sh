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
kubectl rollout status deployment/vllm -n llm-serving --timeout=1200s
