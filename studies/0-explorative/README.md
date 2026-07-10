# 0-Explorative

**Status:** TODO
**Dates:** 2026-07-09 – <end>

## Objective

Establish this repo's first baseline study (`ROADMAP.md` backlog #1: maximize token
throughput, the reference point future studies compare against) while simultaneously
exploring the full parameter surface of the vLLM optimization pack (now **1.3.1** — see
"Stack & versions" below) — a much larger space (26 parameters) than the pack this
repo's pre-restructure study
(`_old/akamas/studies/S3.1-Optimization-Throughput.yaml`) used (5 parameters). This
study is the direct successor to S3.1: same goal, same target stack, rebuilt against the
current pack and this repo's self-contained study layout.

Goal: maximize `vLLM.prefill_token_throughput + vLLM.decode_token_throughput`, no
latency constraint (deliberately — same as S3.1; a latency-SLO-constrained follow-up is
a natural next study once this one shows the throughput/latency Pareto shape).

## Stack & versions

- **Akamas version:** 3.7.x
- **Optimization pack(s) used:** vLLM **1.3.1** (https://gitlab.com/akamas/optimization-packs/vllm,
  branch `feature/attention-backend-and-block-size-categorical` at the time of writing —
  started from tag `1.2.0`, see "Pack update" below for what changed and why). GPU pack:
  name/metrics assumed unchanged from this repo's pre-restructure
  setup (metrics-only, no tunable parameters) — **not verified against a live source for
  this study, see "Assumptions to verify" below.** Kubernetes pack: stock `Kubernetes
  Container` component type, no properties needed.
- **Workload under test:** `vllm/vllm-openai:v0.22.0` serving `Qwen/Qwen2.5-7B-Instruct`
  (served as `qwen2.5-7b`), namespace `llm-serving`.
- **Cluster / hardware:** single NVIDIA A10G GPU (24 GB nominal; actual usable VRAM is
  ~22-22.5 GiB per `nvidia-smi` convention — see the `gpu_memory_utilization` note under
  "Parameter constraints" below, never read live from this cluster, estimated backwards
  from an observed OOM), namespace `llm-serving` for the workload, `llm-benchmark` for
  the load generator, `monitoring` for Prometheus/DCGM.
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

16 of the pack's 26 vLLM parameters are searched; 9 are pinned to fixed values (single
GPU, non-MoE model, or an unsupported feature — see below); 1 (`compilation_mode`) is
deliberately excluded — see notes below the table.

| Parameter | Domain / categories | Baseline |
|---|---|---|
| `vLLM.gpu_memory_utilization` | [0.85, 0.95] | 0.92 |
| `vLLM.max_num_seqs` | [16, 1024] | 128 |
| `vLLM.max_num_batched_tokens` | [256, 8192] | 2048 |
| `vLLM.kv_cache_dtype` | auto, fp8, fp8_e4m3, fp8_e5m2 | auto |
| `vLLM.performance_mode` | balanced, interactivity, throughput | balanced |
| `vLLM.optimization_level` | [0, 3] | 2 |
| `vLLM.dtype` | auto, float16, bfloat16 | auto |
| `vLLM.enforce_eager` | true, false | false |
| `vLLM.scheduling_policy` | fcfs, priority | fcfs |
| `vLLM.prefix_caching_hash_algo` | sha256, sha256_cbor | sha256 |
| `vLLM.disable_cascade_attn` | true, false | true |
| `vLLM.tokenizer_mode` | auto, hf, slow | auto |
| `vLLM.async_scheduling` | true, false | true |
| `vLLM.max_cudagraph_capture_size` | [1, 1024] | 256 |
| `vLLM.block_size` | 16, 32, 48, 64, 80, 96, 112, 128 | 16 |
| `vLLM.attention_backend` | FLASH_ATTN, FLASHINFER, TRITON_ATTN | FLASH_ATTN |

Pinned (not in `parametersSelection`, fixed for every trial via the baseline step):

| Parameter | Value | Why |
|---|---|---|
| `vLLM.tensor_parallel_size` | 1 | Only one GPU available. |
| `vLLM.pipeline_parallel_size` | 1 | Only one GPU available. |
| `vLLM.data_parallel_size` | 1 | Only one GPU available. |
| `vLLM.enable_expert_parallel` | false | Qwen2.5-7B is dense, not MoE; irrelevant. |
| `vLLM.disable_custom_all_reduce` | false (pack default) | Per the pack's own description, only relevant when `tensor_parallel_size > 1`; a no-op at TP=1, not worth spending optimizer budget on. |
| `vLLM.max_model_len` | 32768 (model's native max) | **Moved here 2026-07-10, after live A/B verification on the cluster (see "Manual verification runs" below)** confirmed it has no measurable effect on available KV cache memory for this model/config — vLLM 0.22.0 profiles memory using `max_num_batched_tokens`, not `max_model_len`. With no observed throughput effect either way, it's pinned at the model's own native context length (`max_position_embeddings: 32768`, confirmed from Qwen2.5-7B-Instruct's `config.json`) rather than spending optimizer budget on it. See "Parameters tuned" notes below the table for the full empirical finding (kept for the record, since it corrects an earlier, wrong assumption in this same README). |
| `vLLM.max_num_partial_prefills` | 1 | **Moved here 2026-07-09, after the study had already run experiments** — "Concurrent Partial Prefill" (any value > 1) is not supported on this vLLM 0.22.0 / A10G combo. See "Incident: Concurrent Partial Prefill crash" below. |
| `vLLM.max_long_partial_prefills` | 1 | Same incident — only meaningful when `max_num_partial_prefills > 1`. |
| `vLLM.long_prefill_token_threshold` | 0 | Same incident — same reason (0 = disabled, matches vLLM's own default). |

`vLLM.block_size` was pinned too (2026-07-09, "Incident: invalid block_size" below), but
**moved back to tunable** once the pack itself was fixed (see "Pack update" below): it's
now categorical over the full `[16, 32, 48, 64, 80, 96, 112, 128]` (every multiple of 16
the pack's original cap allows), with the `FLASHINFER`-specific restriction to `{16, 32,
64}` handled by a `parameterConstraint` instead of narrowing the domain for every
backend (see "Parameter constraints" above).

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
- **`vLLM.kv_cache_dtype`** keeps the full `fp8`/`fp8_e4m3`/`fp8_e5m2` range — confirmed
  against vLLM source that `TritonAttentionBackend` and `FlashInferBackend` both declare
  support for all three; only `FlashAttentionBackend` doesn't (see "Parameter
  constraints" below for how that's now guarded rather than just accepted as a risk).
- **`vLLM.max_model_len` — history of this decision (2026-07-10, kept for the record)**.
  Initially considered for pinning on the assumption that it's just "the model's context
  window" and therefore not worth tuning without changing the model. That assumption was
  wrong: verified against vLLM source (`vllm/config/model.py`'s
  `_get_and_verify_max_len`, `v0.22.0` tag), `max_model_len` is a **configurable
  ceiling**, not a fixed model property — vLLM only raises an error if it's set *higher*
  than the model's derived native max (Qwen2.5-7B-Instruct's own `config.json` reports
  `max_position_embeddings: 32768`, confirmed live from Hugging Face); setting it lower
  is always accepted. So it was kept **tunable** instead, on the hypothesis that lowering
  it (this study's load generator always sends fixed-shape requests —
  `prompt_tokens=512,output_tokens=128` = 640 tokens total, see "Stack & versions" above
  — well under any value in its domain) would free GPU memory for more KV cache blocks
  and therefore more throughput.

  **That memory hypothesis was then empirically disproven by a direct A/B test on the
  real cluster (2026-07-10)** — see "Manual verification runs" below: deploying the
  identical config (`FLASH_ATTN`, `kv_cache_dtype=auto`, `block_size=16`,
  `max_num_batched_tokens=2048`) with only `max_model_len` changed (`2048` vs. `32768`)
  produced **identical** `Available KV cache memory` (4.76 GiB) and `GPU KV cache size`
  (89,088 tokens) in both runs — only the *reported* "maximum concurrency for N tokens
  per request" ratio differed (43.50x vs. 2.72x), which is just `89,088 / max_model_len`,
  not an actual difference in reserved memory. vLLM 0.22.0's memory profiling sizes its
  dummy forward pass by `max_num_batched_tokens`, not `max_model_len` — so `max_model_len`
  does **not** measurably affect available KV cache memory for this model/config, and
  therefore has no demonstrated effect on this study's throughput objective either.

  **Decision: `vLLM.max_model_len` is now pinned** (moved out of `parametersSelection`
  into the baseline step's pinned `values`, see "Parameters tuned" table above) at
  `32768` — the model's own native context length — rather than left tunable with no
  demonstrated benefit. Its only confirmed effect remains the length ceiling past which
  vLLM rejects a request, which this study's fixed ~640-token workload never approaches
  regardless of where in `[2048, 32768]` it would have been set — so pinning it at the
  native max costs nothing and removes a dimension from the search space that had no
  measurable payoff.

## Parameter constraints

Akamas studies support a `parameterConstraints` field (documented at
`docs.akamas.io/akamas-docs/using/study/parameters-and-constraints` — **not** covered by
the `akamas-study-manager` plugin's bundled schema reference, which only documents
`goal.constraints`; that's a metric-based, post-hoc check on a *successful* trial's
result, a completely different mechanism from this one) that lets the optimizer be told
to **never generate** a combination of parameter *values* in the first place — confirmed
to support `==`/`!=` on categorical parameters and `&`/`||` boolean logic, not just
numeric inequalities. This directly closes gaps that earlier revisions of this study
could only work around by narrowing domains or accepting a known failure rate:

```yaml
parameterConstraints:
  - name: FLASH_ATTN only supports auto kv_cache_dtype
    formula: vLLM.attention_backend != "FLASH_ATTN" || vLLM.kv_cache_dtype == "auto"
  - name: FlashInfer only supports block_size 16, 32, or 64
    formula: vLLM.attention_backend != "FLASHINFER" || vLLM.block_size == "16" || vLLM.block_size == "32" || vLLM.block_size == "64"
  - name: max_num_batched_tokens must be at least max_num_seqs
    formula: vLLM.max_num_batched_tokens >= vLLM.max_num_seqs
  - name: TRITON_ATTN does not support fp8 kv_cache_dtype on Ampere
    formula: vLLM.attention_backend != "TRITON_ATTN" || vLLM.kv_cache_dtype != "fp8"
  - name: TRITON_ATTN does not support fp8_e4m3 kv_cache_dtype on Ampere
    formula: vLLM.attention_backend != "TRITON_ATTN" || vLLM.kv_cache_dtype != "fp8_e4m3"
  - name: TRITON_ATTN does not support fp8_e5m2 kv_cache_dtype (query-quant bug)
    formula: vLLM.attention_backend != "TRITON_ATTN" || vLLM.kv_cache_dtype != "fp8_e5m2"
```

The first two were found the hard way, from real crashed experiments (see the incidents
above and below) — verified against vLLM 0.22.0's attention backend source
(`vllm/v1/attention/backends/{flash_attn,triton_attn,flashinfer}.py`):
`FlashAttentionBackend.supported_kv_cache_dtypes = ["auto", "float16", "bfloat16"]` (no
fp8 support at all); `FlashInferBackend.get_supported_kernel_block_sizes()` returns
exactly `[16, 32, 64]` while `FlashAttentionBackend`/`TritonAttentionBackend` both accept
any multiple of 16. Because these constraints exist, `vLLM.block_size` no longer needs to
be narrowed to the conservative 3-value intersection — the pack itself was widened back
to the full `[16, 32, 48, 64, 80, 96, 112, 128]` (see "Pack update" below).

The **third was found proactively**, by auditing vLLM's own config validation source for
every `raise ValueError`/`NotImplementedError` touching two or more of this study's
tunable parameters, before it ever caused a failed experiment here — `vllm/config/scheduler.py`'s
`verify_max_model_len` unconditionally rejects `max_num_batched_tokens < max_num_seqs`
(unlike the *other* check in that same method, `max_num_batched_tokens < max_model_len`,
which only fires when chunked prefill is disabled — this repo's template never touches
`--enable-chunked-prefill`, which defaults to enabled, so that specific check doesn't
apply here). Confirmed as a frequently-hit real-world issue independent of this study —
see [vllm-project/vllm#2492](https://github.com/vllm-project/vllm/issues/2492) and
[#18681](https://github.com/vllm-project/vllm/issues/18681). This study's domains
(`max_num_batched_tokens` [256, 8192], `max_num_seqs` [16, 1024]) overlap enough that a
meaningful fraction of otherwise-valid-looking samples would have violated this — e.g.
`max_num_batched_tokens=512` with `max_num_seqs=700` — without ever needing the fp8 or
FlashInfer conditions above.

**Not added as a `parameterConstraint`**: the memory-sizing (`No available memory for the
cache blocks`) failure seen in experiment 2 (2026-07-10) depends on several continuous
parameters at once (`gpu_memory_utilization`, `max_num_batched_tokens`, `max_model_len`,
plus real constants — model weights, activation-memory overhead, and the A10G's actual
usable VRAM) in a way that's hard to express precisely as a single formula without a live
memory reading. Instead, **`gpu_memory_utilization`'s domain was narrowed** from
`[0.5, 0.95]` to `[0.85, 0.95]`, calibrated against the one real data point this crash
provided: model weights measured at **14.29 GiB** (bfloat16), `gpu_memory_utilization
=0.6125` yielding `Available KV cache memory: -1.54 GiB`. Solving backwards against a
commonly-reported A10G usable VRAM of ~22-22.5 GiB (not the vendor-rounded "24 GB") puts
the break-even point around **0.81-0.83** even in the worst case (`max_num_batched_tokens`
at this study's max of 8192, which increases vLLM's internal activation-memory profiling
overhead) — `0.85` adds a small margin above that estimate. This is a **best-effort
estimate, not a guarantee**: the A10G's exact usable VRAM was never read directly via
`nvidia-smi`/DCGM, so occasional OOM failures near the low end of this narrowed domain
are still possible and, if so, are still absorbed by `maxFailedExperiments` — revisit
with a real memory reading if they turn out to be frequent.

`maxFailedExperiments: 200` (not equal to `numberOfExperiments: 1000`, unlike S3.1 which
set both to 1000 and — per the `akamas-study-manager` plugin's own schema
reference — silently disabled the failure guard). 200 gives headroom for the expected
failure sources above while keeping the guard actually active.

### Incident: Concurrent Partial Prefill crash (2026-07-09)

Every experiment except the baseline was failing at the `Apply config` workflow task
(`kubectl rollout status` hitting `ProgressDeadlineExceeded`, pod in `CrashLoopBackOff`).
Direct inspection of the pod logs (`kubectl logs <pod> -n llm-serving --previous`) showed
the real cause — not the boolean-flag issue flagged earlier (that fix, confirmed working:
`disable_cascade_attn`/`async_scheduling` etc. show up correctly parsed as real booleans
in vLLM's own "non-default args" log line) — but this, immediately after argument
parsing succeeds:

```
NotImplementedError: Concurrent Partial Prefill is not supported. We recommend to
remove Concurrent Partial Prefill from your config.
```

i.e. `max_num_partial_prefills > 1` — "Concurrent Partial Prefill" — is rejected outright
by vLLM 0.22.0 on this GPU/backend combination, regardless of the exact value. Since the
parameter's tuned domain was `[1, 8]`, essentially every sampled experiment (any value
other than exactly 1) crashed immediately; only the baseline (which pins it to 1)
survived. This is a harder incompatibility than the "some combinations may fail" risks
already anticipated for `kv_cache_dtype`/FP8 — it's a 100%-reproducible failure for any
non-default value, not an occasional one.

**Fix applied directly to this already-running study** (`studies/0-explorative/akamas/0-Explorative.yaml`),
deliberately deviating from `.claude/rules/akamas-yaml.md`'s normal rule ("changing
`parametersSelection` on a study that has already run experiments requires a new study")
— done by explicit user decision after the user manually stopped the study first, rather
than scaffolding a v2: moved `max_num_partial_prefills`, `max_long_partial_prefills`, and
`long_prefill_token_threshold` out of `parametersSelection` and into the baseline step's
pinned `values` (all three "off": `1`, `1`, `0` — matching vLLM's own defaults for a
disabled chunked/concurrent-prefill feature). The study needs to be re-created on Akamas
(delete + recreate, or whatever update path the user's Akamas version supports for a
`parametersSelection` change) before resuming.

### Incident: invalid `block_size` crash (2026-07-09, same day)

After the fix above, experiments were still crashing — same symptom
(`ProgressDeadlineExceeded` / `CrashLoopBackOff`), different cause. Pod logs
(`kubectl logs <pod> -n llm-serving --previous`) showed the engine core itself dying
during startup:

```
ValueError: No valid attention backend found for cuda with
AttentionSelectorConfig(head_size=128, dtype=torch.bfloat16, kv_cache_dtype=fp8,
block_size=106, ...). Reasons: {FLASH_ATTN: [kv_cache_dtype not supported,
block_size not supported], FLASHINFER: [block_size not supported], TRITON_ATTN:
[block_size not supported], FLEX_ATTENTION: [kv_cache_dtype not supported,
block_size not supported], TURBOQUANT: [kv_cache_dtype not supported,
block_size not supported]}
```

The failing experiment had sampled `block_size=106`. Checked directly against vLLM
0.22.0's attention backend source
(`vllm/v1/attention/backends/{flash_attn,triton_attn,flashinfer}.py`):
`FlashAttentionBackend.get_supported_kernel_block_sizes()` returns `MultipleOf(16)`,
`FlashInferBackend`'s returns exactly `[16, 32, 64]` — **every backend requires
`block_size` to be a multiple of 16** (FlashInfer even more restrictive), but the pack
declares it as a plain integer over `[1, 128]` with no such constraint, and Akamas'
integer domain has no "multiple of" or step mechanism to express it. `block_size=106`
(not a multiple of 16) is therefore rejected by literally every backend regardless of
any other parameter.

This also explains why `kv_cache_dtype=fp8` looked incompatible in the error: it isn't —
`FlashAttentionBackend.supported_kv_cache_dtypes` excludes fp8, but
`TritonAttentionBackend`/`FlashInferBackend` both explicitly support
`fp8`/`fp8_e4m3`/`fp8_e5m2`. With `block_size=106`, though, *none* of them qualify, fp8 or
not — the block size alone was sufficient to fail every backend. `kv_cache_dtype` itself
needed no change.

**Fix applied the same way as the incident above**: `block_size` moved out of
`parametersSelection`, pinned to `16` (vLLM's own default, a valid multiple of 16 for
every backend) in the baseline step's `values`.

**Residual risk**: only `block_size` was checked against source for this
multiple-of/discrete-value class of constraint; the remaining tunable integer parameters
(`max_num_seqs`, `max_num_batched_tokens`, `max_model_len`, `max_cudagraph_capture_size`)
are assumed to accept arbitrary integers in their domain (consistent with what their own
vLLM source comments describe — memory/performance knobs, not backend-capability
enums) but were not each individually source-verified the way `block_size` now has been.
If another 100%-reproducible crash appears, check that parameter's own vLLM source next
before assuming it's another one-off bad sample.

### Incident: `TRITON_ATTN` + fp8 crash on Ampere (2026-07-10)

Experiment 3 crashed with a Triton compilation error, not a vLLM-level `ValueError`:

```
triton.compiler.errors.CompilationError: at 1:0:
def reshape_and_cache_kernel_flash(
^
ValueError("type fp8e4nv not supported in this architecture. The supported fp8 dtypes are ('fp8e4b15', 'fp8e5')")
```

Traced to `vllm/v1/attention/ops/triton_reshape_and_cache_flash.py`, called from
`TritonAttentionBackend.do_kv_cache_update` — this is `attention_backend=TRITON_ATTN`'s
own KV-cache-update kernel, JIT-compiled by Triton at request time (unlike
`FlashInferBackend.do_kv_cache_update`, confirmed to instead call the precompiled C++/CUDA
op `torch.ops._C_cache_ops.reshape_and_cache_flash` — no Triton JIT involved, so this
doesn't affect `FLASHINFER`). Triton's `fp8e4nv` type (the native E4M3 format, used when
`kv_cache_dtype` is `fp8` or `fp8_e4m3`) requires compute capability ≥ 9 (Hopper+); the
A10G is Ampere (compute capability 8.6), which Triton only supports via the older
`fp8e4b15`/`fp8e5` formats — `fp8e5` matches `kv_cache_dtype=fp8_e5m2`, so this specific
*Triton-compilation* failure mode doesn't hit that value. (It turned out to be broken by
a *different* bug instead — see the next incident.)

**Fix**: two `parameterConstraints` (see above) ruling out `attention_backend=TRITON_ATTN`
combined with `kv_cache_dtype` in `{fp8, fp8_e4m3}`. `FLASH_ATTN` was already excluded
from all non-`auto` `kv_cache_dtype` values by the first constraint; `FLASHINFER` is
unaffected (different, non-Triton kernel path) and needs no additional restriction.

### Incident: `TRITON_ATTN` + `fp8_e5m2` crash — separate query-quantization bug (2026-07-10)

Experiment 11 crashed with a plain Python `AssertionError`, not a Triton compilation
error, despite `fp8_e5m2` being the one fp8-family value the previous incident's
analysis expected to be safe for `TRITON_ATTN`:

```
(EngineCore pid=98) ERROR ... assert self.kv_cache_dtype in {"fp8", "fp8_e4m3", "nvfp4"}
(EngineCore pid=98) ERROR ... AssertionError
```

Traced to `vllm/model_executor/layers/attention/attention.py` (v0.22.0 tag). This is an
independent code path from the Triton-JIT `reshape_and_cache` kernel in the previous
incident: at `__init__`, vLLM enables query quantization (`self.query_quant`) whenever
`kv_cache_dtype.startswith("fp8")` — which matches all three of `fp8`, `fp8_e4m3`, *and*
`fp8_e5m2` — **and** the active attention backend's `supports_quant_query_input` is
`True`. But `forward()` then asserts `kv_cache_dtype in {"fp8", "fp8_e4m3", "nvfp4"}`,
which **excludes `fp8_e5m2`** — an inconsistency between vLLM's own enablement condition
and its own assertion, not something this study can influence.

Checked each backend's `supports_quant_query_input` to see who actually hits this:

- `TritonAttentionBackend.supports_quant_query_input = current_platform.is_cuda()` —
  unconditionally `True` on any CUDA GPU, A10G included. **`TRITON_ATTN` always hits this
  assertion when `kv_cache_dtype=fp8_e5m2`.**
- `FlashInferBackend.supports_quant_query_input` requires
  `can_use_trtllm_attention(...)` → `supports_trtllm_attention()`, which itself requires
  `current_platform.is_device_capability_family(100)` (SM100/Blackwell). The A10G is
  SM86 (Ampere) — this is `False`, so **`FLASHINFER` never enables query quantization on
  this hardware** and is unaffected.
- `FlashAttentionBackend` is moot — already excluded from every non-`auto`
  `kv_cache_dtype` by the first constraint above.

Net effect: combined with the previous incident, **`TRITON_ATTN` cannot successfully run
any of the three fp8-family `kv_cache_dtype` values on this A10G** — `fp8`/`fp8_e4m3` via
the Triton-compilation error, `fp8_e5m2` via this assertion. Only `FLASHINFER` can
actually use fp8 KV-cache quantization with any attention backend enabled in this study.

**Fix**: a third `parameterConstraint` (see above) ruling out
`attention_backend=TRITON_ATTN` combined with `kv_cache_dtype=fp8_e5m2`, completing the
exclusion of all three fp8-family values for `TRITON_ATTN`.

### Manual verification runs before resuming the study (2026-07-10)

Before restarting the study with the corrected `parameterConstraints`, several configs
were deployed directly to the live cluster (`kubectl apply` against hand-rendered
copies of `01-deployment_template.yaml`, bypassing Akamas) to confirm they actually work
end-to-end — not just "no longer hit a known crash" — including a real
`/v1/completions` request against each, not just a passing `/health` check:

| Config | Result |
|---|---|
| `FLASHINFER` + `kv_cache_dtype=fp8_e4m3` + `block_size=16` | ✅ loads, FlashInfer warm-up + CUDA graph capture succeed, real completion request returns a correct answer. Confirms `FLASHINFER` is a genuinely working fp8-KV-cache path, not just "not yet observed to crash." |
| `TRITON_ATTN` + `kv_cache_dtype=auto` + `block_size=48` | ✅ loads and serves correctly. Confirms `TRITON_ATTN` itself is healthy once all three fp8-family `kv_cache_dtype` values are excluded for it. |
| `FLASH_ATTN` + `block_size=128` (top of the new categorical range) | ✅ loads and serves correctly — no other hidden block-size restriction for `FLASH_ATTN` at the high end. |
| `max_model_len=2048` (bottom of its domain), rest baseline | ✅ loads and serves correctly. |
| Control: identical config to the row above but `max_model_len=32768` | ✅ loads and serves correctly; used to A/B-test the `max_model_len` memory claim above — see the correction in "Parameters tuned." |

No new failure modes were found across these five runs. Combined with the three
incidents above, this gives reasonable confidence that the current
`parameterConstraints` set closes the failure modes actually observed on this
vLLM 0.22.0 / A10G combination, though — as already noted elsewhere in this
README — the OOM-related `gpu_memory_utilization` domain narrowing remains a
best-effort estimate, not a guarantee, and the wider parameter space (26 parameters)
was not exhaustively swept manually.

### Pack update: `attention_backend` + fixed `block_size` (2026-07-09, pack v1.3.1)

Rather than leave `block_size` permanently pinned, the root cause was fixed at the
source: the vLLM optimization pack itself
(https://gitlab.com/akamas/optimization-packs/vllm, branch
`feature/attention-backend-and-block-size-categorical`, not yet merged) was updated to
`version: 1.3.0`, then `1.3.1` once `block_size` was widened back after
`parameterConstraints` was confirmed to cover the FlashInfer-specific case:

- **`block_size`** changed from a free `integer [1, 128]` to `categorical [16, 32, 48,
  64, 80, 96, 112, 128]` — every multiple of 16 up to the pack's original cap (the full
  range `FLASH_ATTN`/`TRITON_ATTN` accept; `FLASHINFER`'s narrower `{16,32,64}` is now
  guarded by a study-level `parameterConstraints` entry instead of narrowing the pack's
  domain for every backend — see "Parameter constraints" above).
- **`attention_backend`** added as a new categorical parameter (`FLASH_ATTN`,
  `FLASHINFER`, `TRITON_ATTN`), mapping to vLLM's real `--attention-backend` flag, so the
  backend itself is now an explicit, tunable/pinnable choice instead of relying on
  vLLM's own auto-selection (the mechanism that made the original crash possible: silent
  fallthrough to "no valid backend" instead of a validation error at config time).

This went through two revisions on the same branch: the first commit narrowed
`block_size` to the safe 3-value intersection `{16,32,64}` across all three backends
(before `parameterConstraints` was known to support categorical equality + boolean
logic); the second commit widened it back to the full 8-value range once the
`FLASHINFER`-specific restriction could be expressed as a study-level constraint instead
— see "Parameter constraints" above for exactly which constraints replace which
narrowing.

`block_size` is therefore **back in `parametersSelection`** as categorical (now over all
8 values, not just 3), and `attention_backend` is newly added — see the "Parameters
tuned" table above. This requires the pack to actually be built and installed/upgraded
(`akamas build optimization-pack` → `akamas install -f optimization-pack`) on the target
Akamas instance from that branch **before** re-creating this study, or
`vLLM.attention_backend`/the new `block_size` categories won't resolve.

## How to run

**1. Prerequisites (one-time, before creating anything below):**

```bash
# confirm the vLLM pack 1.3.1 (with attention_backend + fixed block_size) is installed
akamas list optimization-pack

# apply the two PVCs by hand — not part of the workflow, see "Assumptions to verify" #6
kubectl apply -f studies/0-explorative/k8s/00-pvc.yaml             # guidellm-results, ns llm-benchmark
kubectl apply -f studies/0-explorative/k8s/01-pvc-model-cache.yaml # vllm-model-cache, ns llm-serving
```

**2. Create the Akamas resources** (typed form, one command per file — safer ordering):

```bash
akamas create system                studies/0-explorative/akamas/system.yaml

akamas create component             studies/0-explorative/akamas/components/container.yaml "vLLM_Benchmark_0_Explorative"
akamas create component             studies/0-explorative/akamas/components/gpu.yaml       "vLLM_Benchmark_0_Explorative"
akamas create component             studies/0-explorative/akamas/components/vllm.yaml      "vLLM_Benchmark_0_Explorative"

akamas create telemetry-instance    studies/0-explorative/akamas/telemetry/prometheus.yaml "vLLM_Benchmark_0_Explorative"

akamas create workflow              studies/0-explorative/akamas/0-Explorative-Workflow.yaml
akamas create study                 studies/0-explorative/akamas/0-Explorative.yaml
```

Or in one shot (bulk form — every file self-describes its `kind:`):

```bash
akamas create -f studies/0-explorative/akamas/
```

**3. Start:**

```bash
akamas start study "0-Explorative"
```

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

All 25 templated flags (everything except the deliberately-excluded `compilation_mode`)
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
