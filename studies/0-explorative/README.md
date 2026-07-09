# 0-Explorative

**Status:** TODO
**Dates:** 2026-07-09 – <end>

## Objective

Establish this repo's first baseline study (`ROADMAP.md` backlog #1: maximize token
throughput, the reference point future studies compare against) while simultaneously
exploring the full parameter surface of the vLLM optimization pack **1.2.0** — a much
larger space (25 parameters) than the pack this repo's pre-restructure study
(`_old/akamas/studies/S3.1-Optimization-Throughput.yaml`) used (5 parameters). This
study is the direct successor to S3.1: same goal, same target stack, rebuilt against the
current pack and this repo's self-contained study layout.

Goal: maximize `vLLM.prefill_token_throughput + vLLM.decode_token_throughput`, no
latency constraint (deliberately — same as S3.1; a latency-SLO-constrained follow-up is
a natural next study once this one shows the throughput/latency Pareto shape).

## Stack & versions

- **Akamas version:** 3.7.x
- **Optimization pack(s) used:** vLLM **1.2.0** (https://gitlab.com/akamas/optimization-packs/vllm,
  tag `1.2.0`). GPU pack: name/metrics assumed unchanged from this repo's pre-restructure
  setup (metrics-only, no tunable parameters) — **not verified against a live source for
  this study, see "Assumptions to verify" below.** Kubernetes pack: stock `Kubernetes
  Container` component type, no properties needed.
- **Workload under test:** `vllm/vllm-openai:v0.22.0` serving `Qwen/Qwen2.5-7B-Instruct`
  (served as `qwen2.5-7b`), namespace `llm-serving`.
- **Cluster / hardware:** single NVIDIA A10G GPU (24 GB), namespace `llm-serving` for the
  workload, `llm-benchmark` for the load generator, `monitoring` for Prometheus/DCGM.
  Cluster provisioning itself is out of this repo's tooling scope — see `ROADMAP.md`.
- **Load generator:** GuideLLM (`ghcr.io/neuralmagic/guidellm:latest`), `guidellm
  benchmark --rate-type throughput --max-seconds 900 --data
  "prompt_tokens=512,output_tokens=128"` — finds maximum sustainable throughput at a
  fixed synthetic prompt/output shape.
- **Telemetry:** Prometheus (`kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`),
  `duration: 30`, `logLevel: DETAILED`. Metric catalog reused verbatim from the
  pre-restructure setup (`_old/akamas/system/telemetry/prometheus.yaml`) — already
  validated against this same cluster.

## Parameters tuned

19 of the pack's 25 vLLM parameters are searched; 5 are pinned to fixed values (single
GPU, non-MoE model); 1 (`compilation_mode`) is deliberately excluded — see notes below
the table.

| Parameter | Domain / categories | Baseline |
|---|---|---|
| `vLLM.gpu_memory_utilization` | [0.5, 0.95] | 0.92 |
| `vLLM.max_num_seqs` | [16, 1024] | 128 |
| `vLLM.max_num_batched_tokens` | [256, 8192] | 2048 |
| `vLLM.max_model_len` | [2048, 32768] | 32768 |
| `vLLM.kv_cache_dtype` | auto, fp8, fp8_e4m3, fp8_e5m2 | auto |
| `vLLM.max_num_partial_prefills` | [1, 8] | 1 |
| `vLLM.max_long_partial_prefills` | [1, 8] | 1 |
| `vLLM.long_prefill_token_threshold` | [0, 8192] | 0 |
| `vLLM.performance_mode` | balanced, interactivity, throughput | balanced |
| `vLLM.optimization_level` | [0, 3] | 2 |
| `vLLM.block_size` | [8, 128] | 16 |
| `vLLM.dtype` | auto, float16, bfloat16 | auto |
| `vLLM.enforce_eager` | true, false | false |
| `vLLM.scheduling_policy` | fcfs, priority | fcfs |
| `vLLM.prefix_caching_hash_algo` | sha256, sha256_cbor | sha256 |
| `vLLM.disable_cascade_attn` | true, false | true |
| `vLLM.tokenizer_mode` | auto, hf, slow | auto |
| `vLLM.async_scheduling` | true, false | true |
| `vLLM.max_cudagraph_capture_size` | [1, 1024] | 256 |

Pinned (not in `parametersSelection`, fixed for every trial via the baseline step):

| Parameter | Value | Why |
|---|---|---|
| `vLLM.tensor_parallel_size` | 1 | Only one GPU available. |
| `vLLM.pipeline_parallel_size` | 1 | Only one GPU available. |
| `vLLM.data_parallel_size` | 1 | Only one GPU available. |
| `vLLM.enable_expert_parallel` | false | Qwen2.5-7B is dense, not MoE; irrelevant. |
| `vLLM.disable_custom_all_reduce` | false (pack default) | Per the pack's own description, only relevant when `tensor_parallel_size > 1`; a no-op at TP=1, not worth spending optimizer budget on. |

**Excluded entirely** (not in `parametersSelection`, not pinned, not referenced by the
deployment template at all): `vLLM.compilation_mode`. Verified against vLLM's own source
(`vllm/config/compilation.py`, `vllm/engine/arg_utils.py` at the `vllm-project/vllm`
`main` branch) that this pack parameter maps to `CompilationConfig.mode`, which has **no
direct top-level CLI flag** — it's only reachable via the nested `--compilation-config`/
`-cc` JSON argument. Meanwhile `vLLM.optimization_level` (kept, tunable) maps to vLLM's
own `OptimizationLevel` preset (`-O0..-O3`, exposed as the real top-level
`--optimization-level` flag), whose own docstring describes it as directly controlling
compilation mode *and* CUDA graph behavior together — i.e. `optimization_level` and
`compilation_mode` likely control overlapping or the same underlying behavior through two
different mechanisms. Rather than risk the optimizer wasting budget on a redundant (or
outright conflicting) dimension, this study keeps `optimization_level` (real, simple,
top-level flag) and excludes `compilation_mode`. **Flag for the pack owner**: consider
whether `compilation_mode` should be removed from the pack, or documented with its actual
required CLI syntax (`--compilation-config '{"mode": N}'`) if it's meant to be
independently useful.

Several other exclusions/narrowings were made deliberately to avoid wasting experiment
budget on combinations very likely to fail outright, verified against vLLM's real source
where possible:

- **`vLLM.dtype`** excludes `float32`: Qwen2.5-7B's weights alone in float32 (~28 GB)
  already exceed the A10G's 24 GB before any KV cache — essentially guaranteed OOM.
- **`vLLM.tokenizer_mode`** excludes `mistral`/`deepseek_v32`/`deepseek_v4`: per
  `vllm/config/model.py`, these are tokenizer implementations for entirely different
  model families and would fail to load Qwen2.5's tokenizer.
- **`vLLM.prefix_caching_hash_algo`** excludes `xxhash`/`xxhash_cbor`: per the pack's own
  parameter description, these require the optional `xxhash` Python package, not
  confirmed installed in the `vllm/vllm-openai:v0.22.0` image.
- **`vLLM.kv_cache_dtype`** keeps the full `fp8`/`fp8_e4m3`/`fp8_e5m2` range even though
  FP8 KV-cache support on an Ampere-generation A10G is unconfirmed — some experiments may
  legitimately fail here; accepted, see `maxFailedExperiments` below.
- **`vLLM.max_long_partial_prefills` vs. `vLLM.max_num_partial_prefills`**: per
  `vllm/config/scheduler.py`, vLLM raises a `ValueError` at startup if
  `max_long_partial_prefills > max_num_partial_prefills`. Akamas has no cross-parameter
  domain constraint mechanism, so some sampled combinations will violate this and fail —
  accepted, not solved.

`maxFailedExperiments: 200` (not equal to `numberOfExperiments: 1000`, unlike S3.1 which
set both to 1000 and — per the `akamas-study-manager` plugin's own schema
reference — silently disabled the failure guard). 200 gives headroom for the expected
failure sources above while keeping the guard actually active.

## Assumptions to verify before running

1. ~~Boolean CLI flag syntax~~ — **confirmed and fixed.** vLLM's boolean CLI flags
   (`enforce-eager`, `disable-cascade-attn`, `async-scheduling`, `enable-expert-parallel`,
   `disable-custom-all-reduce`) use Python's `argparse.BooleanOptionalAction`, confirmed
   both in vLLM's own source at the exact `v0.22.0` tag (not just `main`) and by directly
   testing the stdlib action in isolation: `--flag=true` fails with `"ignored explicit
   argument"`, only bare `--flag` / `--no-flag` is accepted. Rather than change the
   study's `parametersSelection` (the pack declares these as `"true"`/`"false"` string
   categories, fixed), `k8s/apply_config.sh` now rewrites the rendered deployment's
   `--flag=true`/`--flag=false` args into `--flag`/`--no-flag` via `sed`, right before
   `kubectl apply` — see the comment in that script for the exact mechanism.
2. **The GPU component type's declared shape is a stale, unverified snapshot** (carried
   over from this repo's pre-restructure `_old/akamas/optpack/gpu/component-types/gpu.yaml`,
   not re-fetched from a live source for this study). Confirm with
   `akamas describe optimization-pack GPU` before creating the `gpu` component.
3. **The remote `toolbox` host's path convention is assumed, not verified.** The
   workflow points at `/work/vllm-benchmark/studies/0-explorative/k8s/...` for this
   study's own template/scripts, mirroring this git repo's new `studies/` layout — but
   the old workflow only ever pointed at `/work/vllm-benchmark/akamas/...` (the
   pre-restructure flat layout). Confirm the toolbox host's `/work/vllm-benchmark/` tree
   is actually kept in sync with this repo's current structure (or update the paths to
   wherever it really is) before running.
4. **The SSH key path** (`/work/vllm-benchmark/akamas/workflows/id_rsa`) is reused as
   confirmed — rotated after the compromise logged in `ROADMAP.md`'s security debt, same
   path. Double-check this is still accurate at run time.
5. **`--optimization-level` vs. the pack's stated `-O<level>` syntax**: the pack's own
   `parameters.yaml` describes `optimization_level` as using "CLI syntax `-O<level>`",
   but `vllm/engine/arg_utils.py` only shows a top-level `--optimization-level` flag, no
   `-O` short alias — confirmed at both `main` and the exact `v0.22.0` tag this study
   deploys. This study uses `--optimization-level=${vLLM.optimization_level}`; low risk,
   but if the actual deployed vLLM version turns out to need `-O<level>` instead, adjust
   the template accordingly.

All 24 templated flags (everything except the deliberately-excluded `compilation_mode`)
were individually confirmed present, spelled exactly as templated, in
`vllm/engine/arg_utils.py` at the `v0.22.0` git tag itself (not just `main`, which has
since drifted — e.g. gained `--device-ids`, `--model-class-overrides` — confirming `main`
isn't a safe stand-in for the deployed version without this kind of per-tag check).

6. **Two PVCs need to be applied manually, once, before starting the study** — neither is
   applied by `apply_config.sh` or any workflow task (deliberately: a PVC should persist
   across the whole study, not be recreated/torn down per trial like the Deployment/Job
   are). Run once against the target cluster before `akamas start study`:
   ```bash
   kubectl apply -f studies/0-explorative/k8s/00-pvc.yaml            # guidellm-results, ns llm-benchmark
   kubectl apply -f studies/0-explorative/k8s/01-pvc-model-cache.yaml # vllm-model-cache, ns llm-serving
   ```

## Results

<Filled in by the study-recap skill once the study finishes.>

## Conclusions

<Filled in by the study-recap skill once the study finishes.>
