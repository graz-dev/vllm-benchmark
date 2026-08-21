DEPLOY_FILE=/work/vllm-benchmark/studies/2-larger-model-g7e/k8s/01-deployment.yaml

# --- Step 1: boolean CLI flags (same fix as prior studies) ---
# vLLM's boolean flags (enforce-eager, disable-cascade-attn, async-scheduling,
# enable-expert-parallel, disable-custom-all-reduce) use argparse.BooleanOptionalAction,
# which rejects an explicit "--flag=value" form — only bare --flag / --no-flag is
# accepted. The Akamas vLLM pack declares these as categorical "true"/"false" string
# parameters, so FileConfigurator renders "--flag=true"/"--flag=false" into the
# deployment args; rewrite those into the accepted form here, right before applying.
for flag in enforce-eager disable-cascade-attn async-scheduling enable-expert-parallel disable-custom-all-reduce; do
  sed -i "s/--${flag}=true/--${flag}/" "$DEPLOY_FILE"
  sed -i "s/--${flag}=false/--no-${flag}/" "$DEPLOY_FILE"
done

# --- Step 2: strip any vLLM parameter flag left with no rendered value ---
# Only matters if this study's baseline step ever excludes some parameters from
# rendering (as 1-goodput-realistic-load's did) — a no-op on trials where every
# ${vLLM.*} token gets a real, non-empty computed value. Kept as a generic safety net
# regardless of which baseline-rendering design this study's akamas/study.yaml ends up
# using (not yet built — see README "Prerequisites still open" #4).
sed -i -E '/\$\{vLLM\./d; /^[[:space:]]*-[[:space:]]*"--[A-Za-z0-9_-]+="[[:space:]]*$/d' "$DEPLOY_FILE"

kubectl apply -f "$DEPLOY_FILE" -n llm-serving

# Don't let a failed rollout exit immediately — print vLLM's own container logs first,
# so they land in this task's stdout and show up in the Akamas UI (experiment/trial
# view) without needing separate kubectl access.
set +e
kubectl rollout status deployment/vllm -n llm-serving --timeout=1500s
ROLLOUT_EXIT=$?
set -e

echo "--- vLLM container logs (current pod) ---"
kubectl logs deployment/vllm -n llm-serving --tail=200 || true
echo "--- vLLM container logs (previous pod, if it crashed and restarted) ---"
kubectl logs deployment/vllm -n llm-serving --tail=200 --previous 2>/dev/null || true

exit $ROLLOUT_EXIT
