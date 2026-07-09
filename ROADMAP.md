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

- **H1 — `max_num_batched_tokens` drives a TTFT/throughput trade-off** [TO BE CONFIRMED]
  Higher values should increase prefill throughput but lengthen TTFT and ITL under load;
  the optimum is expected to sit somewhere in the middle of the parameter's domain, not
  at either extreme. The exact sweet spot depends on the GPU/model — a study should
  record the domain and result it actually observed. Range cross-check: independent
  sources give different ranges depending on model/hardware —
  `knowledge/notes/2026-07-vllm-recipe-llama3-3-70b.md` baselines 8192 (up to 16384) for
  Llama-3.3-70B on B200/H100/H200, while `knowledge/notes/2026-07-auto-tune-vllm.md`'s
  own example configs search 1024–8192 or 2048–16384 — confirms a study's domain should
  be derived from its own model/hardware, not copied from either source.

- **H2 — `gpu_memory_utilization` shows diminishing returns past some threshold**
  [TO BE CONFIRMED] Once the KV cache stops being the bottleneck for a given
  model+workload, pushing utilization higher should mostly raise OOM/instability risk
  without a throughput gain. Verify against `kv_cache_usage_max` and `preemption_rate`.
  Range cross-check: two independent sources (`knowledge/notes/2026-07-practical-vllm-performance-tuning.md`'s
  manual "push toward 0.95" guidance and `knowledge/notes/2026-07-auto-tune-vllm.md`'s
  own 0.85–0.95 search range) both center on a narrow band above vLLM's 0.9 default
  rather than the full [0,1] domain — a reasonable prior for a study's domain, to
  confirm against its own hardware headroom rather than assume. Alternative study-design
  pattern worth considering, per
  `knowledge/notes/2026-07-vllm-official-auto-tune-script.md` (vLLM's own upstream
  `auto_tune.sh`): rather than searching `gpu_memory_utilization` jointly with
  `max_num_seqs`/`max_num_batched_tokens`, calibrate its safe ceiling once (highest
  value that avoids OOM for the model+hardware) and hold it fixed, scoping
  `parametersSelection` to just the other two parameters. If H2 is confirmed
  (diminishing returns near the top of the range), this removes a search dimension the
  optimizer would likely converge to the top of anyway, potentially speeding up
  convergence — worth trying for backlog #1, the first baseline study, as a comparison
  against the standard three-parameter joint search.

- **H3 — `max_num_seqs` saturates before its upper bound** [TO BE CONFIRMED]
  Beyond some concurrency level, throughput should stop growing (compute/KV saturation)
  while tail latency (ITL/TTFT p95) keeps worsening. If confirmed for a given
  model/hardware pair, narrow that study family's domain to speed up convergence.
  Additional supporting evidence (see
  `knowledge/notes/2026-07-distributed-inference-advanced-deployment-patterns.md`):
  speculative decoding's throughput gain shrinks or inverts at large batch sizes, because
  an already-saturated decode fleet has little idle forward-pass capacity left for a
  draft model to exploit — another case of "more concurrency isn't purely additive"
  alongside this hypothesis and H2.

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
  `parametersSelection`.

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
  README. If both get used, it may be worth a note in `knowledge/` comparing their
  measurement methodology (e.g. how each defines TTFT/ITL) before comparing results
  across studies that used different tools.
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

## B. Prioritized study backlog

| # | Study | Target component(s) | Objective (sketch) | Status |
|---|-------|----------------------|---------------------|--------|
| 1 | [0-explorative](studies/0-explorative/README.md) | vLLM | Maximize token throughput (no latency constraint, matching the pre-restructure S3.1 study it replaces) — the first study to establish a baseline, now against the full 25-parameter vLLM pack 1.2.0 rather than the old 5-parameter pack | TODO |
| 2 | `<tbd>` | vLLM + Kubernetes | Tests H4: co-tune vLLM parameters with container CPU/memory requests-limits, compare best-found config against study #1's vLLM-only result | IDEA |
| 3 | `<tbd>` | GPU / vLLM | Energy efficiency: maximize tokens/s per watt (formula using a GPU power-draw metric). Candidate first experiment/prior, per `knowledge/notes/2026-07-ai-systems-performance-serving-tuning-checklist.md`: "for some models, going from a 100% to 80% power limit yields nearly the same speed at 20% less power usage" — worth testing power-capping as a near-free win before assuming max power limit is optimal. Note the installed GPU pack is currently metrics-only (no tunable parameters, per this repo's own tracking at the time) — confirm with `akamas describe optimization-pack GPU` whether a power-limit parameter exists before scoping `parametersSelection`; if not, power capping may need to happen outside Akamas (e.g. a workflow task) | IDEA |
| 4 | `<tbd>` | vLLM + Kubernetes (replicas/HPA) | Tests H4's replication mechanism: under-allocate `gpu_memory_utilization`/`max_num_seqs` below the single-replica optimum, run N replicas per GPU, maximize aggregate throughput vs study #1's single-replica best (see `knowledge/notes/2026-07-gpu-memory-bound-large-batch-inference.md`) | IDEA |

Before activating a study: run `/new-study` (reads this roadmap and `knowledge/README.md`
for you), pick a real name, and let it scaffold `studies/<name>/` from the template.
Once scaffolded, replace the `<tbd>` row above with the real study name and a link.

## C. Consolidated learnings

> Empty — no study has completed in this repo's current structure yet. Once one does,
> `study-recap` distills its README's "Conclusions" section into a short bullet here,
> and updates the hypotheses in section A accordingly.

- _(no consolidated learnings yet)_

### Debt / non-study actions
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
      categorically larger than for general chat (~1.5–2.5×)), KV cache dtype/quantization
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
      Run:ai, MIG, time-slicing, or MPS) before scoping backlog #4's replica-count
      study, per `knowledge/notes/2026-07-gpu-fractioning-nvidia-runai.md`. If one is
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
      unsuitable for tightly-coupled parallel jobs like TP-sharded inference) and MPS
      (soft concurrent kernel sharing across processes, no hard isolation) are two
      distinct mechanisms with different trade-offs from each other and from Run:ai's
      fractional scheduler — confirm which one (if any) specifically, not just whether
      "a scheduler" exists.
