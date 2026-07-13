# ROADMAP — living plan across studies

This file holds what cuts **across** studies — what to try next. For a factual recap of
what's already been built and observed, see `studies/README.md` instead. What's specific
to one study — its exact stack, versions, parameters, and results — lives in that
study's own `studies/<name>/README.md`, not here (see `README.md` on why studies are
self-contained). Update this file:
- whenever a cross-study hypothesis is born, confirmed, or retired (section A);
- whenever a study is decided, started, or completed (section B);
- at the end of a study, via the `study-recap` skill (section C).

---

## A. Hypotheses / open questions

> All hypotheses below are **TO BE CONFIRMED**: they come from general vLLM-tuning
> literature and reasoning, not from measured results in this repo yet. They're
> intentionally stated without hardware/model specifics — those belong to whichever
> study actually tests them, in that study's own README.

- **H1 — `max_num_batched_tokens` drives a TTFT/throughput trade-off** [TO BE CONFIRMED —
  not cleanly testable by study #1] `studies/0-explorative` searched this jointly with 15
  other parameters via Akamas' optimizer (not a controlled single-variable sweep), and its
  goal metric is throughput-only (no TTFT/latency term) — across its 80 finished trials,
  `max_num_batched_tokens` showed essentially **zero raw correlation with the throughput
  goal** (Pearson r ≈ 0.02). That's not evidence against the trade-off itself (the goal
  formula can't see TTFT), just a note that this study's design can't confirm or refute
  H1 as stated — a future study would need either a TTFT term in its goal/constraints or
  a dedicated single-parameter sweep to test this properly. Range cross-check unchanged:
  independent sources give different ranges depending on model/hardware —
  `knowledge/notes/2026-07-vllm-recipe-llama3-3-70b.md` baselines 8192 (up to 16384) for
  Llama-3.3-70B on B200/H100/H200, while `knowledge/notes/2026-07-auto-tune-vllm.md`'s
  own example configs search 1024–8192 or 2048–16384 — confirms a study's domain should
  be derived from its own model/hardware, not copied from either source.

- **H2 — `gpu_memory_utilization` shows diminishing returns past some threshold**
  [PARTIALLY CONFIRMED, within a pre-narrowed range — see `studies/0-explorative/README.md`]
  That study narrowed this parameter's domain to `[0.85, 0.95]` for OOM-avoidance reasons
  (not to test H2), so the full `[0,1]` range was never explored — but *within* that
  narrow, already-high band, `gpu_memory_utilization` showed only a weak correlation with
  the throughput goal (Pearson r ≈ 0.15) across 80 finished trials, consistent with H2's
  "diminishing returns" shape near the top of the range, though not a strong enough
  signal to call this conclusively settled. The alternative study-design pattern below
  (calibrate once, hold fixed) looks more attractive given this weak effect — a future
  study could reasonably spend less optimizer budget on this dimension. Range
  cross-check unchanged: two independent sources
  (`knowledge/notes/2026-07-practical-vllm-performance-tuning.md`'s manual "push toward
  0.95" guidance and `knowledge/notes/2026-07-auto-tune-vllm.md`'s own 0.85–0.95 search
  range) both center on a narrow band above vLLM's 0.9 default rather than the full [0,1]
  domain. Alternative study-design pattern worth considering, per
  `knowledge/notes/2026-07-vllm-official-auto-tune-script.md` (vLLM's own upstream
  `auto_tune.sh`): rather than searching `gpu_memory_utilization` jointly with
  `max_num_seqs`/`max_num_batched_tokens`, calibrate its safe ceiling once (highest
  value that avoids OOM for the model+hardware) and hold it fixed, scoping
  `parametersSelection` to just the other two parameters.

- **H3 — `max_num_seqs` saturates before its upper bound** [LEANS REJECTED for
  Qwen2.5-7B-Instruct / single A10G — see `studies/0-explorative/README.md`] Across that
  study's 80 finished trials, `max_num_seqs` showed a *positive* correlation with the
  throughput goal (Pearson r ≈ 0.36, no goal-metric plateau observed toward the domain's
  upper end: trials with `max_num_seqs` in the top half of `[16, 1024]` averaged ~13%
  higher throughput than the bottom half) — no clear saturation within the range tested,
  contrary to H3's premise. **But** the two experiments that failed with an OOM
  (`max_num_seqs` 917 and 1016, both near the domain ceiling, both paired with
  near-maximum `gpu_memory_utilization`) show this parameter does hit a *reliability*
  ceiling before it hits a *throughput* one — worth carrying into any future test of this
  hypothesis: check for a reliability cliff (crash rate), not just a throughput plateau,
  when raising `max_num_seqs`. This is one model/GPU pair's result, not a general claim —
  a future study on different hardware (more/less VRAM, different vocab size) should
  re-test rather than assume this transfers.
  Additional supporting evidence (see
  `knowledge/notes/2026-07-distributed-inference-advanced-deployment-patterns.md`):
  speculative decoding's throughput gain shrinks or inverts at large batch sizes, because
  an already-saturated decode fleet has little idle forward-pass capacity left for a
  draft model to exploit — another case of "more concurrency isn't purely additive"
  alongside this hypothesis and H2, even though this specific study's data leans against
  a throughput-side saturation for this stack.

- **H4 — co-tuning Kubernetes resource limits alongside vLLM parameters changes the
  optimum** [TO BE CONFIRMED] Akamas can tune Kubernetes-level parameters (container
  CPU/memory requests/limits, HPA settings, ...) in the same study as vLLM parameters.
  Whether jointly optimizing both finds a materially better configuration than tuning
  vLLM alone (with "reasonable" fixed k8s resources) is untested — worth a dedicated
  study once a vLLM-only baseline exists to compare against. A specific mechanism worth
  testing (see `knowledge/notes/2026-07-gpu-memory-bound-large-batch-inference.md`):
  deliberately under-allocating `gpu_memory_utilization`/`max_num_seqs` below the
  single-replica optimum frees GPU memory that a second (or third) vLLM replica on the
  same GPU can use, potentially beating a single maximally-tuned replica on aggregate
  throughput — this needs a Kubernetes-pack replica-count/HPA parameter tuned jointly
  with the vLLM ones, see backlog #4. For what that parameter should ideally represent,
  see `knowledge/notes/2026-07-nvidia-dynamo-planner.md`: NVIDIA Dynamo's Planner is a
  concrete example of an SLA-aware autoscaler that scales prefill and decode replica
  counts *independently* (compute-bound vs. memory/KV-bound) rather than one aggregate
  replica count — a single Kubernetes replica-count parameter may not be expressive
  enough for a disaggregated topology, though it's sufficient for this repo's current
  non-disaggregated studies. Strongest quantitative evidence yet for this hypothesis's
  underlying pattern, per `knowledge/notes/2026-07-gpu-fractioning-nvidia-runai.md`:
  NVIDIA Run:ai's GPU-fractioning benchmarks show two 0.5-GPU Llama-3.1-8B replicas
  reaching ~305K tokens/s combined vs. ~199K tokens/s for one full-GPU replica on the
  same hardware — the same "smaller allocation × more replicas beats one big
  allocation" shape as "Mind the Memory Gap," but via a **different mechanism**:
  scheduler-level GPU fractioning (Run:ai-specific, hard memory isolation across
  independent Pods) rather than vLLM-internal `gpu_memory_utilization` tuning within one
  process. If the target cluster has a GPU-sharing scheduler, the missing Kubernetes
  parameter needs a **GPU-fraction-per-replica** dimension (Request/Limit), not just a
  replica count — but this entire mechanism is conditional on that scheduler (Run:ai,
  MIG, time-slicing, or MPS) actually being installed on whatever cluster a study runs
  against; confirm before assuming it's available.

- **H5 — `tensor_parallel_size`'s optimum is a "minimum that fits," not a value worth
  sweeping freely** [TO BE CONFIRMED] Per
  `knowledge/notes/2026-07-distributed-inference-scaling-dimensions.md`, general
  guidance for dense models is: quantize first, then set the minimum TP degree that fits
  the model plus KV cache headroom on the target GPU, then scale further capacity via
  data parallelism (replicas) rather than higher TP — higher TP only pays off under a
  strict single-request TTFT SLO. If confirmed, a study tuning `tensor_parallel_size`
  should narrow its domain around that computed minimum instead of the pack's full
  range, and treat DP (replica count) as the throughput lever instead — ties into H4/
  backlog #4's replica-count question. A related but distinct angle, per
  `knowledge/notes/2026-07-practical-vllm-performance-tuning.md`: for a *fixed* GPU
  budget, the split between replica count and TP degree per replica (e.g. 16 GPUs as 4
  replicas × TP=2, 2 replicas × TP=4, or 1 replica × TP=8) is itself an empirical
  trade-off — not just "minimum TP, then add replicas," but "given N total GPUs, which
  TP/replica split wins," which also interacts with HA/scheduling-flexibility needs, not
  just throughput. Worth testing explicitly if a study ever has a fixed multi-GPU budget
  to allocate, distinct from backlog #4's single-GPU replica-packing question. Note per
  `knowledge/notes/2026-07-nvidia-dynamo-aiconfigurator.md`: if a future multi-GPU
  study's topology is decided externally (e.g. via a topology-planning tool) before the
  study starts, `tensor_parallel_size` may not need to be an Akamas-searched parameter
  at all for that study — it would already be pinned by the topology decision, and only
  per-instance parameters within that fixed topology would go into
  `parametersSelection`. Concrete numbers to sanity-check a future TP>1 study against,
  per `knowledge/notes/2026-07-generative-ai-on-kubernetes-gpu-production-patterns.md`:
  tensor-parallel communication overhead can consume **50-70% of inference time** if the
  interconnect is poorly partitioned (the reason it's recommended single-node-only, with
  NVLink/NVSwitch — cross-node bandwidth is roughly two orders of magnitude slower);
  within one node, ~4 GPUs deliver "approximately three and a half times" one GPU's
  throughput for a well-optimized model (near-linear but not perfectly so) — a future
  study measuring TP scaling efficiency below that ballpark should suspect interconnect
  or partitioning issues before concluding TP itself doesn't pay off. **Node-provisioning
  prerequisite to check before that study, per
  `knowledge/notes/2026-07-generative-ai-on-kubernetes-training-job-scheduling.md`**: the
  Kubernetes Topology Manager (Kubelet component, policies `none`/`best-effort`/
  `restricted`/`single-numa-node`) coordinates CPU/GPU NUMA locality — cross-NUMA-socket
  memory access costs roughly 3x the latency of local access, which can eat into TP's
  own communication budget on a multi-socket node if the pod's GPUs and pinned CPUs land
  on different sockets. Worth confirming the target node's Topology Manager policy (and
  that the GPUs assigned to a TP>1 pod are NUMA-local) as part of that study's setup, not
  something Akamas tunes — a provisioning check, like the NVLink/NVSwitch interconnect
  check already noted above. **Concrete GPU-count sizing formula to compute that
  "minimum that fits" from first principles**, per
  `knowledge/notes/2026-07-inference-engineering-techniques-quantization-speculation-parallelism.md`:
  `vram_required = (bits_precision / 8) × params_billions × kv_cache_allocation_factor`
  — round up to the nearest available instance size to get the minimum GPU count, then
  derive the minimum TP degree from that. The same source states Tensor Parallelism
  "should be your default strategy" for multi-GPU inference (supports both dense and MoE
  models), reinforcing this hypothesis's premise, and gives a firm general rule worth
  citing directly: "unless your model and KV cache are so large as to require multi-node
  inference, it probably isn't the best use of extra hardware — better off scaling
  replicas horizontally, or disaggregating."

- **H6 — `tensor_parallel_size` and `max_num_seqs` should not be analyzed as independent
  effects within a single replica** [TO BE CONFIRMED] Per
  `knowledge/notes/2026-07-vllm-recipe-llama3-3-70b.md` (vLLM-project's own Llama-3.3-70B
  recipe): raising TP shards the KV cache across more GPUs, freeing per-GPU headroom that
  can let `max_num_seqs` run higher than it could at lower TP — partially offsetting TP's
  own per-request throughput cost. If a study's `parametersSelection` searches both
  parameters together, its results analysis should look for this coupling (e.g. does the
  optimizer converge to a higher `max_num_seqs` at higher TP than at lower TP) rather than
  reporting each parameter's marginal effect as if the other were held constant. Distinct
  from H5 (TP vs. replica *count* across GPUs) — this is TP vs. batch size *within* one
  replica.

- **Q1 — Windowing**: for a given load-test duration, does `trim` windowing reliably
  capture steady state, or does a given study need `stability` windowing instead? Decide
  per study based on how variable that study's load generator's ramp-up is.
- **Q2 — Load generator choice**: studies so far have used GuideLLM; NVIDIA's
  GenAI-Perf/AIPerf is being evaluated as an alternative. This is a **per-study**
  decision, not a repo-wide default — document the actual tool + version in each study's
  README. Now backed by `knowledge/notes/2026-07-llm-inference-load-testing-tools.md`'s
  methodology comparison — concretely: GuideLLM and vLLM's own `benchmark_serving.py`
  are open-loop (arrivals scheduled independent of responses; `benchmark_serving.py`
  additionally supports a `--burstiness` gamma-distribution knob GuideLLM's poisson/
  constant split doesn't have), while AIPerf/GenAI-Perf keeps a fixed number of
  concurrent requests active continuously (closed-loop-style) and defines
  ITL/TPOT as `(e2e_latency − TTFT) / (total_output_tokens − 1)` — a different
  concurrency model *and* a different formula than GuideLLM's. If both tools ever get
  used across studies, don't compare raw numbers directly: record which tool, which
  rate-type/concurrency mode, and note that fixed-concurrency (AIPerf-style) runs can
  look artificially stable under saturation compared to true open-loop (GuideLLM
  `constant`/`poisson`, or `benchmark_serving.py`'s Poisson/gamma) runs at "the same"
  load.
- **Q3 — Optimization pack versions**: pack lifecycle (which parameters/metrics exist)
  is managed outside this repo. When a study starts, record in its README exactly which
  pack versions were installed at the time — packs can change independently of this repo.
- **Q4 — Prefix-cache hit rate as a hard constraint, not just an observed metric**: per
  `knowledge/notes/2026-07-vllm-official-auto-tune-script.md`, vLLM's own `auto_tune.sh`
  supports `MIN_CACHE_HIT_PCT` as an admission gate — a configuration that tanks cache
  hit rate shouldn't win purely on throughput. Worth adopting as a `goal.yaml` constraint
  for any future RAG-shaped or prompt-reuse-heavy study. First confirm with
  `akamas describe optimization-pack vLLM` whether the installed pack exposes an actual
  cache-*hit-rate* (reuse) metric, distinct from the cache-*usage*/occupancy metric
  already referenced by H2 — this repo's own tracking at the time only confirmed the
  latter.
- **Q5 — What granularity does the installed GPU pack's "utilization" metric actually
  report?**: per `knowledge/notes/2026-07-modal-gpu-glossary.md`, `nvidia-smi`-style GPU
  utilization can report 100% while a kernel occupies under 1% of an H100's streaming
  multiprocessors — "GPU utilization" is not a reliable proxy for compute saturation
  unless it's specifically an SM-level (or finer, e.g. per-pipe/tensor-core) metric.
  Before trusting a GPU-utilization reading in any study's results (including H2's
  verification metrics and backlog #3's energy-efficiency study), confirm via
  `akamas describe optimization-pack GPU` which granularity the installed pack's metric
  actually measures.
- **Q6 — Is llm-d worth adopting for backlog #4's multi-replica work?** Per
  `knowledge/notes/2026-07-llm-d-distributed-inference-platform.md`, llm-d is a
  Kubernetes-native orchestration layer above vLLM (KV-cache-aware routing, prefill/
  decode disaggregation, SLO-aware autoscaling via `InferencePool`/`InferenceModel`
  CRDs) — same category as Dynamo's Planner/aiconfigurator already tracked here: a
  topology/deployment choice made *before* a study starts, not a vLLM parameter change.
  It's N/A for this repo's current single-GPU/single-replica scope; revisit only once
  backlog #4/H4-H6 actually reach multi-replica territory. If adopted then, llm-d's own
  routing/scaling policy (EPP scoring weights, prefill:decode pool ratio, autoscaling
  SLO targets) would need a **new routing-component pack type** — not an extension of
  the existing vLLM component — flag as a fresh pack request at that time rather than
  now. **Concrete, falsifiable thresholds for when disaggregation (llm-d, Dynamo, or
  otherwise) is worth it at all**, per
  `knowledge/notes/2026-07-inference-engineering-techniques-quantization-speculation-parallelism.md`:
  reach for it only when **all three** hold — serving 100M-1B+ tokens/day (scale-
  dependent on model size), serving a model of at least ~100B parameters, and traffic
  that is prefill-heavy with long input sequences. This repo's studies (single 7B-class
  model, single replica, no production traffic) fail the first two cleanly — a sharper,
  more falsifiable statement than the previous qualitative "N/A until multi-replica
  scope," worth citing here instead of just asserting non-applicability.
- **Q7 — Does this repo's telemetry config actually point at vLLM's real Prometheus
  metric names?** Per
  `knowledge/notes/2026-07-generative-ai-on-kubernetes-model-observability.md`, vLLM
  exposes metrics under names like `vllm:time_to_first_token_seconds`,
  `vllm:num_requests_waiting`, `vllm:prompt_tokens_total`/`vllm:generation_tokens_total`
  (distinct from — and not fully mirrored by — OpenTelemetry's competing semantic-
  convention names, e.g. no OTel equivalent exists for the throughput metric at all).
  This repo's `telemetry-instance` configs (e.g.
  `studies/0-explorative/akamas/telemetry/prometheus.yaml`) were inherited from the
  pre-restructure setup and, per that study's own README, were never independently
  re-verified against a live vLLM `/metrics` endpoint. Worth a one-time check (e.g.
  `curl <vllm-pod>:8000/metrics` against a running study) that every `vLLM.*` Akamas
  metric identity actually maps to the real underlying vLLM metric name, before trusting
  results from a study whose telemetry config was copied forward rather than verified.
- **Operating practice — diagnosing anomalous study runs**: per
  `knowledge/notes/2026-07-distributed-inference-blueprints-troubleshooting.md`'s
  troubleshooting playbook, when a study's results look off, check TTFT and TPOT
  together (not just the goal metric) before concluding a parameter caused a regression,
  and avoid changing more than one scheduler-adjacent parameter between experiments where
  possible so a symptom can be attributed. Concretely: a TPOT rise with flat TTFT and
  climbing KV-cache utilization points to preemption/fragmentation, not the parameter
  under test — worth ruling out before trusting an experiment's result. This is a
  practice to apply when interpreting results, not a hypothesis to confirm/deny itself.
  Two more named symptom→fix mappings, per
  `knowledge/notes/2026-07-ai-systems-performance-serving-tuning-checklist.md`'s Table
  16-1: a KV cache preemption warning in the vLLM scheduler log points to insufficient
  KV cache space — try raising `gpu_memory_utilization` or lowering
  `max_num_batched_tokens`, not the parameter under test; a cache-hit rate below ~60%
  under load points to unbalanced shard placement or a missing/misconfigured prefix
  cache — check the prefix-caching config before attributing a throughput drop to the
  parameter under test.
- **Operating practice — don't run autoscaling during a controlled Akamas experiment**:
  per `knowledge/notes/2026-07-nvidia-dynamo-planner.md`, LLM-aware autoscalers
  (Dynamo's Planner and likely others) terminate workers on scale-down **without
  draining in-flight requests** — if any future study (e.g. backlog #4's replica-count
  work) runs with autoscaling active during a load test, a scale-down event could drop
  in-flight requests and look like a vLLM-parameter effect. Freeze/disable autoscaling
  (or pin replica count) during a controlled experiment, or explicitly account for
  autoscaling events in that study's methodology if it's testing the autoscaler itself.
  **This generalizes beyond Dynamo's Planner** — per
  `knowledge/notes/2026-07-kubernetes-cluster-config-autoscaling-multitenancy.md`, an
  open vLLM RFC (vllm-project/vllm#24885) confirms vLLM's own SIGTERM handling has been
  **inconsistent historically**: it doesn't reliably wait for in-flight requests to
  finish today, regardless of which autoscaler (KEDA/HPA included) triggers the
  scale-down. Until that's hardened upstream, this practice applies to *any*
  autoscaler-driven scale-down of vLLM pods, not just Dynamo-specific tooling. If
  backlog #4 does add autoscaling, the same note names concrete tools to evaluate: KEDA
  (pod-level, scales on `vLLM.num_requests_waiting` — a metric this repo's telemetry
  already tracks), Karpenter (node-level provisioning, complementary to KEDA not an
  alternative), and Kueue (multi-tenant GPU quota fairness, if the cluster is ever
  shared across studies/teams). **Concrete knob names any such autoscaling parameter
  set would need to expose**, per
  `knowledge/notes/2026-07-inference-engineering-production-autoscaling-deployment.md`:
  min replicas, max replicas, autoscaling window (sliding timeframe for decisions),
  scale-down delay (grace period before removing a replica), and concurrency target
  (requests per replica before scaling up — must match the replica's actual batch-size
  configuration or the autoscaler's capacity model is wrong). Worth using as a checklist
  once backlog #4 is actually scoped, not a new pack-request by itself.

## B. Prioritized study backlog

| # | Study | Target component(s) | Objective (sketch) | Status |
|---|-------|----------------------|---------------------|--------|
| 1 | [0-explorative](studies/0-explorative/README.md) | vLLM | Maximize token throughput (no latency constraint, matching the pre-restructure S3.1 study it replaces) — the first study to establish a baseline, against the vLLM pack 1.3.1 (16 of 26 parameters tuned). **Result: +12.5% over baseline** (`FLASHINFER`+`fp8_e4m3`+`block_size=32`), with lower latency and higher success rate too — not a throughput/latency trade-off at this optimum. | DONE |
| 2 | `<tbd>` | vLLM + Kubernetes | Tests H4: co-tune vLLM parameters with container CPU/memory requests-limits, compare best-found config against study #1's vLLM-only result | IDEA |
| 3 | `<tbd>` | GPU / vLLM | Energy efficiency: maximize tokens/s per watt (formula using a GPU power-draw metric). Candidate first experiment/prior, per `knowledge/notes/2026-07-ai-systems-performance-serving-tuning-checklist.md`: "for some models, going from a 100% to 80% power limit yields nearly the same speed at 20% less power usage" — worth testing power-capping as a near-free win before assuming max power limit is optimal. Note the installed GPU pack is currently metrics-only (no tunable parameters, per this repo's own tracking at the time) — confirm with `akamas describe optimization-pack GPU` whether a power-limit parameter exists before scoping `parametersSelection`; if not, power capping may need to happen outside Akamas (e.g. a workflow task) | IDEA |
| 4 | `<tbd>` | vLLM + Kubernetes (replicas/HPA) | Tests H4's replication mechanism: under-allocate `gpu_memory_utilization`/`max_num_seqs` below the single-replica optimum, run N replicas per GPU, maximize aggregate throughput vs study #1's single-replica best (see `knowledge/notes/2026-07-gpu-memory-bound-large-batch-inference.md`) | IDEA |

Before activating a study: run `/new-study` (reads this roadmap and `knowledge/README.md`
for you), pick a real name, and let it scaffold `studies/<name>/` from the template.
Once scaffolded, replace the `<tbd>` row above with the real study name and a link.

## C. Consolidated learnings

- **`studies/0-explorative`** (Qwen2.5-7B-Instruct, single A10G, vLLM 0.22.0): a
  `parameterConstraint` written purely to stop a crash can also mark the actual optimum,
  not just a guardrail — `FLASHINFER` was the *worst*-performing attention backend when
  restricted to `kv_cache_dtype=auto` (the only value the other two backends could use
  safely), but became the best overall once paired with fp8-family quantization
  (`fp8_e4m3` specifically), which is exactly the pairing the crash investigation had
  already restricted to `FLASHINFER` for correctness reasons. Worth checking for this
  pattern in future studies: a constraint born from a crash may be pointing at the
  interesting part of the search space, not just fencing off a bad one.
- **`studies/0-explorative`**: vLLM's own memory accounting (the `gpu_memory_utilization`
  budget / "Available KV cache memory" it reports) does **not** cover every memory
  consumer — a dummy sampler-warmup step allocates a buffer sized roughly
  `max_num_seqs × vocab_size`, *after* weights+KV cache are already reserved, and this
  caused an OOM at `max_num_seqs≈900-1000` combined with `gpu_memory_utilization` near
  the top of its range, even though vLLM's own reported KV-cache budget looked fine.
  Narrowing `gpu_memory_utilization`'s domain alone doesn't fully guard against this —
  future studies with a similarly high `max_num_seqs` ceiling should watch for this
  specific failure mode too, not just the KV-cache-deficit OOM the domain narrowing
  targets.

### Debt / non-study actions
- [ ] **Evaluate Run:ai Model Streamer to cut per-experiment model-load time**, per
      `knowledge/notes/2026-07-generative-ai-on-kubernetes-production-tuning-routing.md`.
      Every Akamas experiment in this repo's studies pays a 5-15 min model-load cost
      before the actual load test starts (see `studies/0-explorative/README.md`'s own
      timing notes) — model loading is called out as the single biggest lever in vLLM's
      startup-time breakdown. `--load-format runai_streamer` (with
      `--model-loader-extra-config '{"concurrency": 16}'`) needs no model repackaging,
      unlike CoreWeave Tensorizer/fastsafetensor which require pre-serialization — worth
      trying against this repo's actual model/PVC setup before committing to any
      pre-serialization approach. Not an Akamas parameter — a workflow/Deployment-level
      flag change to test manually, potentially cutting wall-clock time across every
      future study's experiment count. **Second, independent motivation for this same
      evaluation**, per
      `knowledge/notes/2026-07-inference-engineering-production-autoscaling-deployment.md`:
      quantizing model weights also speeds up *cold-start* loading time itself, not just
      steady-state inference throughput — this repo's per-experiment model-load cost is
      exactly a cold-start cost, so this is a second lever (alongside Model Streamer)
      worth testing, not just an inference-throughput side effect.
- [ ] **If vLLM's multi-node Ray executor backend is ever adopted** (for TP/PP spanning
      multiple nodes, per H5's "minimum TP that fits" discussion), check
      `knowledge/notes/2026-07-generative-ai-on-kubernetes-training-job-scheduling.md`'s
      security caveat first: Ray ships with **no built-in authentication/encryption by
      default** (explicitly documented as "not built for use in untrusted environments") —
      any process with network access to the Ray cluster can execute arbitrary code.
      Mitigation is a Kubernetes `NetworkPolicy` deny-all-by-default + explicit allow
      rules scoped to the Ray cluster's pods, not something vLLM configures itself. N/A
      for every study so far (all single-node) — flagged for if/when this changes.
- [ ] **SECURITY**: this repo's git history contains a real, unencrypted private SSH key
      committed in an earlier revision (path `akamas/workflows/id_rsa` at the time).
      Revoke/rotate it wherever it grants access, and treat it as compromised regardless
      of whether the file is still present on disk — removing a file from the working
      tree does not remove it from git history; that requires a history rewrite.
- [ ] Provision (or document access to) the shared cluster/environment studies will run
      against — currently out of this repo's tooling scope, but at least one study will
      need somewhere real to run.
- [ ] Scaffold and run the first real study under `studies/` via `/new-study`.
- [ ] **Pack request**: pipeline parallelism (`pipeline_parallel_size`), expert
      parallelism (MoE expert count / EPLB toggles), decode/prefill context parallelism
      (`--decode-context-parallel-size`, `--prefill-context-parallel-size`), and
      prefill/decode disaggregation topology are all vLLM CLI flags discussed in
      `knowledge/notes/2026-07-distributed-inference-scaling-dimensions.md` but not
      present in the installed vLLM optimization pack's parameter list as of 2026-07-08
      (per this repo's own tracking at the time). Only
      `tensor_parallel_size` and data-parallelism-via-replicas are currently reachable.
      Re-check with `akamas describe optimization-pack vLLM` before starting any
      multi-node or MoE-topology study — if still missing, raise with the pack owner.
      Also missing, per
      `knowledge/notes/2026-07-distributed-inference-advanced-deployment-patterns.md`:
      speculative decoding config (method + draft-model reference, e.g. vLLM's
      `--speculative-config` — prioritize this ask if any future study is RAG-shaped or
      has high input/output overlap: per
      `knowledge/notes/2026-07-speculative-decoding-survey.md`, the achievable speedup
      for such workloads (9–12× for grammar-correction-like tasks, 2–3× for RAG) is
      categorically larger than for general chat (~1.5–2.5×)). **Sharper operational
      nuance for this same ask**, per
      `knowledge/notes/2026-07-inference-engineering-techniques-quantization-speculation-parallelism.md`:
      production engines don't just see speculative decoding's benefit shrink at large
      batch sizes, they **dynamically disable it** once compute saturates and there's no
      longer spare capacity to afford draft-token verification — if/when this parameter
      is added to the installed pack, confirm whether it needs to be modeled as a static
      method/draft-model choice alone or should also expose a batch-size-conditional
      toggle to match how production engines actually behave. KV cache dtype/quantization
      (`--kv-cache-dtype`, FP8/FP4 —
      the more plausible near-term ask since it's a single per-instance flag), and
      KV-transfer connector selection / disaggregated pool topology (the latter is a
      deployment-architecture choice, not a per-instance parameter — confirm with the
      pack owner whether it belongs in a component's parameter list at all, or should
      stay a fixed choice made before a study starts). Also check for a **KV-cache
      preemption-threshold parameter**, per
      `knowledge/notes/2026-07-distributed-inference-blueprints-troubleshooting.md` — its
      troubleshooting playbook names preemption tuning as the fix for a TPOT-rise +
      climbing-KV-utilization symptom, but it wasn't listed in this repo's tracked vLLM
      parameter summary at the time; confirm with `akamas describe optimization-pack
      vLLM`. Also check, per
      `knowledge/notes/2026-07-auto-tune-vllm.md` (an independent OpenShift-affiliated
      vLLM auto-tuning project's own parameter list): `swap_space` (CPU-offload swap
      space for KV cache), `max_seq_len_to_capture` (CUDA-graph capture length), `dtype`
      (model compute dtype), `enforce_eager` (disable CUDA graphs), `scheduling_policy`
      (`fcfs`/`priority`), and `scheduler_delay_factor`. Separately, check whether
      **`data_parallel_size`** exists as a vLLM-internal parameter in the installed
      pack — if so, it may close the H4/backlog #4 Kubernetes replica-count gap from
      *inside* the vLLM component itself, without needing Kubernetes-pack support at
      all.
- [ ] **Evaluate NVIDIA Dynamo's `aiconfigurator`** for deployment-topology planning
      (aggregated vs. disaggregated, TP/PP degree, prefill/decode worker count, GPU
      count/type) ahead of any future multi-GPU or MoE study, per
      `knowledge/notes/2026-07-nvidia-dynamo-aiconfigurator.md`. This doesn't require
      pack support — it's a way to fix topology *before* scaffolding a study (via
      `/new-study`) rather than asking Akamas or the pack owner to model topology search
      directly. Coverage is limited to its pre-profiled model/GPU database (GPT/LLAMA/
      Qwen/Mixtral/DeepSeek-V3 on H100/H200/A100/B200/GB200) — check whether a study's
      actual model/GPU is covered before relying on it, and still validate its output
      with real load testing (GuideLLM, per Q2) rather than trusting its simulated
      estimate alone.
- [ ] **Confirm whether the target cluster has a GPU-sharing scheduler** (NVIDIA
      Run:ai, MIG, time-slicing, MPS, or a Dynamic Resource Allocation (DRA) driver)
      before scoping backlog #4's replica-count study, per
      `knowledge/notes/2026-07-gpu-fractioning-nvidia-runai.md` and
      `knowledge/notes/2026-07-kubernetes-gpu-scheduling-patterns.md`. If one is
      available, backlog #4 should test GPU-fraction-per-replica (not just replica
      count) as an additional dimension — this is a cluster/infra capability, not
      something the installed vLLM/Kubernetes packs currently model (confirm with
      `akamas describe optimization-pack vLLM`/`Kubernetes`, or the pack's own repo,
      https://gitlab.com/akamas/optimization-packs/vllm), and ties into the
      existing "Provision/document access to the shared cluster" debt item above: record
      which GPU-sharing mechanism (if any) that cluster has as part of that provisioning
      work. This isn't a binary yes/no — per
      `knowledge/notes/2026-07-ai-systems-performance-serving-tuning-checklist.md`, MIG
      (hard-partitioned GPU instances, up to 7 slices, guaranteed resources but
      unsuitable for tightly-coupled parallel jobs like TP-sharded inference — confirmed
      by `2026-07-kubernetes-gpu-scheduling-patterns.md`: MIG instances don't expose
      NVLink between them, so TP≥2 can't span MIG slices) and MPS (soft concurrent
      kernel sharing across processes, no hard isolation) are two distinct mechanisms
      with different trade-offs from each other and from Run:ai's fractional scheduler —
      confirm which one (if any) specifically, not just whether "a scheduler" exists.
      Also check the cluster's **Kubernetes version**: DRA (the newer, more expressive
      API for partial/topology-aware device requests) graduated to GA in **v1.34**
      (Sept 2025) — if the cluster predates that, DRA-based fractional GPU requests
      aren't available regardless of which GPU-sharing mechanism is otherwise installed.
      **Correction, per `2026-07-generative-ai-on-kubernetes-gpu-production-patterns.md`**:
      even on a v1.34+ cluster, **NVIDIA's own DRA driver is still a technical preview
      as of early 2026, not supported for production** — don't treat DRA as a viable
      path yet regardless of Kubernetes version; the device-plugin + label-based
      scheduling model (nodeSelector/affinity/taints, per the same source) remains the
      thing to actually check for and use today. Same source also notes MIG's
      isolation/granularity trade-off is explicitly framed as suited to *many small
      models sharing a GPU*, not this repo's single-large-model-per-GPU case — worth
      keeping in mind if backlog #4 is ever scoped around MIG specifically.
