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

### Current verified status
- **RTL_SIMULATED**: HDM decoder + HPA→DPA translator — **15/15 checks pass on
  Icarus 12.0 and Verilator 5.020** (independent engines must agree).
  Logs: `evidence/raw/{icarus,verilator}_tb_hdm_decode_run.log`.

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
