# Project 2 — PCIe Gen5 / CXL Type-3 Memory-Expansion Validation Platform

A **validation & application-logic platform** built around the boundary of an
authorised vendor CXL Type-3 IP (Agilex 7 R-Tile target). This repository is the
project-owned, vendor-neutral logic **after** the licensed CXL IP boundary — it
is *not* a clean-room CXL PHY/DLL/transaction-layer, and makes no CXL-compliance
claim.

> Result classes are kept strictly separate (RTL_SIMULATED, SOFTWARE_EMULATED,
> SYNTHESIZED, TIMING_ANALYZED, FPGA_MEASURED, BLOCKED, NOT_RUN). See
> [`docs/limitations.md`](docs/limitations.md) and
> [`evidence/claims_matrix.csv`](evidence/claims_matrix.csv). Nothing is claimed
> without a raw log under `evidence/`.

## Quick start (FREE lane — no licence, no board)

```bash
make inventory   # regenerate tool/host inventory -> evidence/environment_inventory.json
make lint        # Verilator -Wall lint of project-owned RTL
make unit        # run unit testbenches under BOTH Icarus and Verilator (both must pass)
make all-free    # inventory + lint + unit
```

`make all-free` never invokes Quartus, XSim, or hardware programming, and never
requires a commercial licence or connected FPGA.

### Current verified status (admission control plane, M1–M4)
All results are **RTL_SIMULATED + FORMAL** (no silicon/board). Each block is
differentially verified against an **independent Python reference model** on a
**two-toolchain** cross-check (system Icarus 12.0 + Verilator 5.020 **and** OSS CAD
Suite Icarus 14.0 + Verilator 5.051), a reduced **AMD XSim 2025.2** third engine,
and **SymbiYosys** bmc + induction + cover with formal-mutation non-vacuity.

- **M1 — HDM decode / translate / config**: fail-closed window decode, HPA→DPA
  translate with complete 64-byte bounds, freeze→drain→atomic-commit config FSM.
- **M2 — outstanding tracker**: composite `{generation,slot}` tags, stale/non-live
  classification, timeout **quarantine** (never silently freed), occupancy.
- **M3 — credit manager**: multi-pool ledger, all-or-nothing consume/return,
  representability-checked atomic config, saturating diagnostics.
- **M4 Phase 1 — registered reclaim** handshake (request/response, held under
  backpressure); classification priority + `SUPERSEDED` proven; commit on accept.
- **M4 Phase 2a — combinational commit sidebands** + per-entry credit-vector
  storage (same-edge credit return).
- **M4 Phase 2b — atomic admission datapath**: one `req_accept` event drives
  tracker alloc + credit consume + issue enqueue together (proved); credit
  **conservation** `credit_used[p] == Σ live stored_credit[p]` proved by induction
  as **mathematical** equality (non-wrapping accumulator + upper-bits-zero); A2 as
  a DUT theorem; epoch capture.
- **M4 Phase 2c — one atomic global configuration commit**: HDM/capacity/timeout/
  credit-maxima/epoch bundled and committed on a **single** `global_cfg_commit_fire`
  after freeze + full drain; no partial update; no live entry crosses a commit;
  conservation preserved across commits. Formal single + five-instance matrix
  (prove+cover), 32/32 sim + 23/23 formal mutations killed.
- **M5 — read/write scheduler** (`rw_scheduler`): after admission, schedules
  transactions to an abstract tagged memory backend with **cross-address reordering
  but per-address program order preserved** by an age-matrix hazard interlock.
  Proved by induction: the age matrix is a strict total order, a younger
  same-address access never reaches memory before the older one completes,
  done⇒issued, response integrity. Five-instance matrix; 36/36 sim + 26/26 formal
  mutations killed. **Safety only — no liveness/fairness claim.**

Per-block contracts: [`docs/config_contract.md`](docs/config_contract.md),
[`docs/admission_contract.md`](docs/admission_contract.md),
[`docs/tracker_contract.md`](docs/tracker_contract.md),
[`docs/credit_contract.md`](docs/credit_contract.md).

**Defensible résumé wording:** *"CXL Type-3 admission and control-plane RTL —
implemented atomic HDM/timeout/credit configuration, generation-tagged outstanding
tracking, timeout quarantine and registered reclaim, multi-pool credit
conservation, and epoch-coupled request admission; differentially tested across
documented parameter configurations and safety-verified using SymbiYosys."* No CXL
protocol-compliance, PHY/link-operation, silicon-validation, PCIe-bandwidth or
tapeout claim; formal results hold for the documented parameter instances, not
universally.

### Reproduce (control plane)
```bash
source tools/oss-cad-suite/environment   # or add tools/oss-cad-suite/bin to PATH
bash scripts/run_control_plane_sweep.sh   # differential, both engines
sby -f formal/control_plane.sby           # bmc + prove(induction) + cover
sby -f formal/control_plane_matrix.sby    # five-instance matrix
bash scripts/run_mutation_tests.sh        # simulation mutations
bash scripts/run_formal_mutation.sh       # formal mutations
bash scripts/run_xsim_crosscheck.sh       # AMD XSim third engine
```

### Requirements (present on the reference host)
Verilator 5.020, Icarus 12.0, GTKWave, Python 3.12, make, gcc. QEMU 8.2.2 (with
`cxl-type3`) for the software lane. See `docs/environment_inventory.md`.

## Architecture (target datapath)
```
licensed CXL IP boundary
  -> vendor adapter -> request normalizer -> HDM range validator
  -> HPA->DPA translator -> outstanding tracker -> read/write scheduler
  -> AXI memory bridge -> DDR4 controller / portable DDR latency model
  -> response reorder -> vendor adapter
```
Implemented so far: `rtl/interfaces/cxl_types_pkg.sv`, `rtl/core/hdm_decoder.sv`,
`rtl/core/dpa_translator.sv`, with `tb/sv/tb_hdm_decode.sv`.

## Repository layout
`rtl/` project-owned RTL · `tb/` testbenches · `sim/` per-simulator build dirs ·
`qemu/` CXL Type-3 software lane · `quartus/` Agilex integration (BLOCKED here) ·
`host/` post-silicon tooling · `docs/` · `evidence/` raw logs + claims matrix.

## What this is NOT
No proprietary CXL PHY/DLL/transaction-layer, no vendor IP redistribution, no
fabricated results. Blocked lanes (Quartus/R-Tile, hardware, SerDes) are marked
BLOCKED with evidence in `docs/limitations.md`.
