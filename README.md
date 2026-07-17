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

### Current verified status (hardened M1)
- **RTL_SIMULATED**: FREEZE→DRAIN→atomic-COMMIT config → fail-closed decode →
  HPA→DPA translate. ~30k differential checks/engine against an **independent
  Python reference model** across `N_WIN∈{1,2,4,8}` and `(HPA_W,DPA_W)∈
  {(32,24),(40,32),(44,36)}` on Icarus 12.0 + Verilator 5.020, a reduced **AMD
  XSim 2025.2** tri-engine cross-check, and **6/6 mutation tests**.
- **FORMAL (verified)**: `make formal` runs SymbiYosys (local OSS CAD Suite,
  rootless) — bounded model check + **unbounded induction** safety proofs, plus
  **cover** tasks demonstrating non-vacuity, plus a **formal-mutation** check
  (breaking a protection makes the proof fail). Covers decoder/translator
  containment + translation, and the config FSM (atomic commit from an immutable
  pending snapshot, drain-before-commit, TOCTOU-safety, epoch monotonicity,
  reset-from-each-state).
- Bounds cover the **complete 64-byte cache line** (HPA+63 in window, DPA+63 <
  capacity), guard-bit arithmetic throughout.
- The config controller proves **the active configuration stays stable until
  admission is frozen and all reported outstanding transactions drain**.
  Per-request epoch capture is deferred to M2 (needs the outstanding tracker).
- Defensible résumé wording: *"Implemented a parameterized HDM-style window
  decoder and HPA-to-DPA translator with fail-closed overlap handling, complete
  64-byte bounds checking and freeze/drain atomic configuration; cross-simulator
  verified with Icarus, Verilator and XSim, with safety properties formally
  verified using SymbiYosys."* Not yet a full "CXL Type-3 validation platform" —
  see `evidence/claims_matrix.csv`.

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
