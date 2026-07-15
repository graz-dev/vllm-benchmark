DEPLOY_FILE=/work/vllm-benchmark/studies/1-goodput-realistic-load/k8s/01-deployment.yaml

# --- Step 1: boolean CLI flags (same fix as 0-explorative) ---
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

# --- Step 2: strip any still-unsubstituted vLLM parameter token (baseline step) ---
# The baseline step's `doNotRenderParameters: ["vLLM.*"]` (see akamas/1-Goodput-Realistic-Load.yaml)
# tells Akamas not to compute a value for ANY vLLM.* parameter for that step, so this
# study's baseline is a genuinely "bare" vLLM startup (just model/port/host), not every
# tunable flag re-stated at its default. With `ignoreUnsubstitutedTokens: true` on the
# workflow's FileConfigurator task (confirmed via Akamas' own live docs, 2026-07-15:
# https://docs.akamas.io/akamas-docs/reference/workflow-operators/fileconfigurator-operator.md),
# any ${vLLM.*} token with no computed value is left as the literal unsubstituted string
# in the rendered file rather than causing a failure — this step removes those lines
# entirely so the baseline command only has the flags hardcoded directly in the template
# (never any literal "${vLLM.foo}" text, which would otherwise break vLLM's argv parsing).
# This is a generic rule — it does nothing on optimize-step trials, where every ${vLLM.*}
# token in the template DOES get a real computed value and this pattern never matches.
sed -i '/\${vLLM\./d' "$DEPLOY_FILE"

# --- Step 3: drop speculative decoding flags entirely when disabled ---
# vLLM.spec_method's "none" value (the pack's own default, meaning "speculative decoding
# off") cannot be passed through to vLLM as a literal --spec-method/--spec-tokens value:
# argparse rejects "none" as an invalid --spec-method choice, and Pydantic rejects
# spec_tokens=0 (num_speculative_tokens requires > 0 when set). Both flags must be
# OMITTED from the command entirely whenever spec_method is "none" — confirmed against
# vLLM v0.22.0 source, see knowledge/notes/2026-07-vllm-pack-v1.5.0-speculative-decoding-gate-pattern.md
# and the pack's own README ("Workflow/deployment-template instructions"). This applies
# to every trial (baseline included, since "none" is also the baseline's own value for
# this parameter when rendered) — a value-based check, distinct from Step 2's
# unsubstituted-token check above.
if grep -q -- '--spec-method=none' "$DEPLOY_FILE"; then
  sed -i '/--spec-method=none/d; /--spec-tokens=0/d' "$DEPLOY_FILE"
fi

kubectl apply -f "$DEPLOY_FILE" -n llm-serving

# Don't let a failed rollout exit immediately — print vLLM's own container logs first,
# so they land in this task's stdout and show up in the Akamas UI (experiment/trial
# view) without needing separate kubectl access.
set +e
kubectl rollout status deployment/vllm -n llm-serving --timeout=1200s
ROLLOUT_EXIT=$?
set -e

echo "--- vLLM container logs (current pod) ---"
kubectl logs deployment/vllm -n llm-serving --tail=200 || true
echo "--- vLLM container logs (previous pod, if it crashed and restarted) ---"
kubectl logs deployment/vllm -n llm-serving --tail=200 --previous 2>/dev/null || true

exit $ROLLOUT_EXIT
