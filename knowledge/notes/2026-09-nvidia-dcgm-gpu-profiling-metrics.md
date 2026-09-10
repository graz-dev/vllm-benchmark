# NVIDIA Run:ai — GPU Profiling Metrics (the DCGM counter reference set)

**Source:** NVIDIA Run:ai documentation, [GPU profiling metrics](https://run-ai-docs.nvidia.com/saas/platform-management/monitor-performance/gpu-profiling-metrics) (vendor doc, DCGM field catalog)
**Date distilled:** 2026-09-10

## Problem addressed

Which DCGM fields a GPU-monitoring stack should export to describe a GPU's behavior under
load — the counter set NVIDIA itself uses in Run:ai's node/workload dashboards. It is a
catalog, not a study: 33 DCGM fields grouped as clocks, temperature, power, PCIe,
utilization, errors, memory, NVLink, vGPU, remapped rows (memory health), one label
(`DCGM_FI_DRIVER_VERSION`) and the "DCP" profiling group (`DCGM_FI_PROF_*`). Useful as a
completeness check for a `dcgm-exporter` counters CSV.

## Levers / parameters touched

No tunable knobs — the design choice is *which counters to export*, and in particular
the distinction between two kinds of field:
- **Device fields** (`DCGM_FI_DEV_*`): `GPU_UTIL`, `MEM_COPY_UTIL`, `ENC/DEC_UTIL`,
  `FB_USED/FREE`, `SM_CLOCK/MEM_CLOCK`, `GPU_TEMP/MEMORY_TEMP`, `POWER_USAGE`,
  `TOTAL_ENERGY_CONSUMPTION` (mJ since boot), `PCIE_REPLAY_COUNTER`, `XID_ERRORS`,
  `*_REMAPPED_ROWS`/`ROW_REMAP_FAILURE`, `NVLINK_BANDWIDTH_TOTAL` and per-lane
  `NVLINK_BANDWIDTH_L0`, `VGPU_LICENSE_STATUS`.
- **Profiling fields** (`DCGM_FI_PROF_*`, need DCGM profiling/DCP support):
  `GR_ENGINE_ACTIVE`, `SM_ACTIVE`, `SM_OCCUPANCY`, `PIPE_TENSOR_ACTIVE`, `DRAM_ACTIVE`,
  `PIPE_FP16/FP32/FP64_ACTIVE`, `PCIE_TX/RX_BYTES` (rates), `NVLINK_TX/RX_BYTES`.

## Key results

- 33 fields total. Cross-checked 2026-09-10 against this repo's
  `dcgm_counters.csv` (studies 7–9): 30 were already exported; the only gaps were the
  three NVLink ones — `DCGM_FI_DEV_NVLINK_BANDWIDTH_L0`, `DCGM_FI_PROF_NVLINK_TX_BYTES`,
  `DCGM_FI_PROF_NVLINK_RX_BYTES`. Our CSV also exports 12 fields the page does not list
  (`FB_TOTAL/RESERVED/USED_PERCENT`, `POWER_MGMT_LIMIT`, `CLOCK_THROTTLE_REASONS`,
  `PSTATE`, `SLOWDOWN_TEMP`, `FAN_SPEED`, `COUNT`, identity labels).
- Hardware-dependent availability, verified on a `g6.12xlarge` (4x L4, dcgm-exporter
  4.8.3): every NVLink field publishes **no series** ("Failed to initialize
  NvSwitch/NvLink info: no switches to monitor" — L4 is PCIe-only);
  `DCGM_FI_PROF_PIPE_FP64_ACTIVE` is skipped ("metric not enabled"); `FAN_SPEED` has no
  series (passively cooled); `XID_ERRORS` produces no series while no XID has occurred.
  38 DCGM metric families actually land in Prometheus out of ~50 requested.
- Scraped through the Prometheus Operator, the DCGM series' `pod` label is the
  **exporter's own pod**; the GPU-consuming pod is `exported_pod` (with
  `exported_namespace`/`exported_container`). A query meant to scope to the workload must
  filter on `exported_pod`.
- `FB_USED` on an idle L4 is ~2 MiB; with vLLM weights loaded it is ≥ several GB — a
  `> 1 GiB` threshold cleanly separates "GPU in use by the model" from idle, which is what
  `vLLM.active_gpus` and `vLLM.gpu_memory_allocated_gb` (vLLM pack 1.8.0) rely on.

## Implications for vLLM/k8s tuning

- Treat this page as the minimum export set for any GPU node group; the repo's CSV is a
  superset of it as of 2026-09-10. Keep NVLink fields in the CSV even on PCIe-only nodes
  (they cost nothing and light up on A100/H100-class hardware), but expect them empty on
  L4/L40S/T4-class GPUs — an empty NVLink metric there is not a collection failure.
- For saturation analysis prefer the profiling fields (`SM_ACTIVE`, `SM_OCCUPANCY`,
  `PIPE_TENSOR_ACTIVE`, `DRAM_ACTIVE`) over `GPU_UTIL`, which only says "a kernel was
  running" (see the Modal GPU glossary note). `DRAM_ACTIVE` vs `PIPE_TENSOR_ACTIVE` is the
  memory-bound vs compute-bound tell for LLM decode.
- `TOTAL_ENERGY_CONSUMPTION` is a since-boot counter in mJ — use `increase()` over the
  trial window for energy per trial, not the raw value.
- Because the dcgm-exporter ConfigMap is shared by every study on the cluster, the CSV
  in the repo must be the source of truth: on 2026-09-10 the live ConfigMap carried two
  fields (`POWER_VIOLATION`, `THERMAL_VIOLATION`) no study CSV listed, and re-applying
  from the repo dropped them until the CSV was fixed.

## Which Akamas parameters to explore

N/A — a metrics catalog, no tunable parameter. Pack coverage: the GPU optimization pack
maps every field on this page as of **1.2.0** (`gpu_nvlink_bandwidth_l0`,
`gpu_nvlink_tx_bytes`, `gpu_nvlink_rx_bytes` added on branch
`feature/nvlink-profiling-counters`; everything else was already in 1.1.0). No new
`ROADMAP.md` question needed — it reinforces Q5 (what the GPU pack's "utilization"
metric actually measures) rather than opening a new one.
