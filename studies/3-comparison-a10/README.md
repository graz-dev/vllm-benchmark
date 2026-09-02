# 3-Comparison-A10

**Status:** TODO
**Dates:** —

## Objective

A direct hardware comparison, not a new question: re-run `2-larger-model-g7e`'s exact
config — same model (`Qwen/Qwen2.5-7B-Instruct`), same goal formula
(`vLLM.prefill_token_throughput + vLLM.decode_token_throughput`), same SLA constraints
(TTFT P95 ≤ 1500ms, ITL P95 ≤ 300ms), same `windowing`, same `parametersSelection`, same
load generator/sweep — but scheduled on the **existing A10G node group**
(`llm-serving`, `g5.2xlarge`, from `0-explorative`/`1-goodput-realistic-load`) instead
of `2-larger-model-g7e`'s own `llm-serving-g7e` (RTX PRO 6000 Blackwell, `g7e.4xlarge`).
Hardware is the only intended variable between this study and `2-larger-model-g7e` —
see that study's own README for the full per-parameter rationale, incident history, and
model-swap background; this README only documents what's actually different here.

**Scaffolded 2026-09-02** (`rsync` of `2-larger-model-g7e`, `akamas/id_rsa` and
`results/export.gz` deliberately excluded — see "Differences from
2-larger-model-g7e" below) after `2-larger-model-g7e`'s own investigation found only a
small goodput improvement over baseline and left open whether that was attributable to
this repo's model (ruled out — see that study's "Model swap") or to the g7e/Blackwell
hardware itself (SM120 kernel-maturity questions, memory-bandwidth differences vs.
Hopper/Ampere). This study exists to answer that question directly: run the identical
config on A10G/Ampere, the hardware `0-explorative`'s own `parameterConstraints` were
originally root-caused on, and compare.

## Differences from `2-larger-model-g7e`

Everything not listed here is identical — same `akamas/*.yaml` structure (only
resource/system/telemetry/workflow names renamed to keep them unique
instance-wide, per this repo's convention), same `k8s/*.yaml` structure, same
`parametersSelection`, same `goal`, same `windowing`.

1. **Node targeting** — `k8s/01-deployment_template.yaml` and `01-deployment.yaml`:
   `nodeSelector: node-role: llm-serving-g7e` → `node-role: llm-serving` (the existing
   A10G group). No new node group provisioned — `infra/eks/cluster.yaml` here is
   identical to `1-goodput-realistic-load`'s own (just the `llm-serving` group,
   `g5.2xlarge`), not `2-larger-model-g7e`'s (which added a separate `llm-serving-g7e`
   group). Turn the A10G group back on (`desiredCapacity` 0→1) if it's currently
   scaled down before running — see `infra/README.md`.
2. **Container resources** — `g5.2xlarge` has only 32GiB total RAM vs.
   `g7e.4xlarge`'s 128GiB. `2-larger-model-g7e`'s `32Gi`/`100Gi` request/limit would
   never schedule here — reverted to `1-goodput-realistic-load`'s own values
   (`16Gi`/`28Gi`), which already run this exact model on this exact node group.
3. **`parameterConstraints`** — `2-larger-model-g7e` (2026-08-27) removed all 6
   constraints it inherited from `1-goodput-realistic-load` to test whether they were
   Ampere-specific carried-forward assumptions on different hardware, then re-added 3
   based on real observed failures on g7e: `FLASH_ATTN`+non-`auto` `kv_cache_dtype`
   (vLLM's own CUDA platform validation, hardware-independent), and `TRITON_ATTN`/
   `FLASHINFER` + `fp8_e5m2` (a query-quantization bug confirmed vLLM-wide via source
   inspection, not hardware-specific). This study **re-adds the remaining 2**
   Ampere-specific exclusions (`TRITON_ATTN`+`fp8`, `TRITON_ATTN`+`fp8_e4m3`) that
   `0-explorative` root-caused **on this exact A10G hardware** and that
   `2-larger-model-g7e` never re-tested (it only confirmed the `fp8_e5m2` case is
   hardware-independent, not these two) — pre-emptively excluded rather than
   rediscovered via a crash, since this study is going back to the hardware they were
   found on. Also re-added 2 more that `1-goodput-realistic-load`/`0-explorative`
   still carry, but that `2-larger-model-g7e` never got around to re-adding after its
   own 2026-08-27 removal (its selective re-adds only followed failures actually
   observed in that study's own trials, and these two hadn't surfaced there) — neither
   is hardware-specific, both are vLLM's own kernel/scheduler requirements, so there's
   no reason to wait for a crash to re-add them here: `FlashInfer` only supports
   `block_size` 16/32/64, and `max_num_batched_tokens` must be ≥ `max_num_seqs`.
   All 7 constraints together: `FLASH_ATTN`+non-`auto`,
   `TRITON_ATTN`+`fp8`, `TRITON_ATTN`+`fp8_e4m3`, `TRITON_ATTN`+`fp8_e5m2`,
   `FLASHINFER`+`fp8_e5m2`, `FlashInfer`+`block_size`,
   `max_num_batched_tokens`≥`max_num_seqs`.
4. **DCGM Exporter** — `2-larger-model-g7e` needed its own new Helm release
   (`dcgm-exporter-g7e`) for its new node group. This study reuses the **existing**
   `dcgm-exporter` release already targeting `llm-serving` (from `0-explorative`'s
   provisioning) — nothing to install, `k8s/monitoring/dcgm-exporter-values.yaml` here
   just documents what's already running, same as `1-goodput-realistic-load`'s own copy.
5. **Excluded from the scaffold**: `akamas/id_rsa` (would have duplicated an
   already-committed SSH private key into a second location — supply your own, same
   convention as `studies/_TEMPLATE`) and `results/export.gz` (that was
   `2-larger-model-g7e`'s own result data, not applicable here).
6. **Akamas resource names** — renamed to keep every system/telemetry-instance/
   workflow/study name unique instance-wide (this repo's convention): study
   `3-Comparison-A10`, system `vLLM_Benchmark_3_Comparison_A10`, telemetry instance
   `Prometheus_3_Comparison_A10`, workflow `3-Comparison-A10-Workflow`.

## Prerequisites before this study can be started

- Turn the A10G `llm-serving` node group back on if scaled down (`desiredCapacity`
  0→1) — see `infra/README.md`.
- Confirm the `vllm-model-cache` PVC lands in the same AZ as wherever the A10G node
  schedules (same class of AZ-mismatch issue `2-larger-model-g7e` hit repeatedly with
  its own node group — recreate the PVC if it's pinned to a different AZ).
- Supply `akamas/id_rsa` (excluded from this scaffold, see above).
- Clear the shared AIPerf dataset cache
  (`/benchmarks/sharegpt-cache/inputs.json` on the `aiperf-results` PVC) if it
  currently has a different model's name baked in — same class of stale-cache bug
  `2-larger-model-g7e` hit twice; check before trusting the first real run.
- Validate every `akamas/*.yaml` file against a live Akamas instance
  (`akamas create -f ...`) before declaring this study ready — not yet done for this
  scaffold.

## How to run

```bash
akamas create -f studies/3-comparison-a10/akamas/
akamas start study "3-Comparison-A10"
```

## Results

<Filled in by the study-recap skill once the study finishes.>

## Conclusions

<Filled in by the study-recap skill once the study finishes.>
