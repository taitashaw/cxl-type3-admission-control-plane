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
- **RTL_SIMULATED**: registered-config → fail-closed decode → HPA→DPA translate.
  ~29k differential checks/engine against an **independent Python reference
  model** across a **1/2/4/8-window, reduced/production-width sweep** on both
  Icarus 12.0 and Verilator 5.020, plus a reduced **AMD XSim** tri-engine
  cross-check, plus **5/5 mutation tests** proving each protection is observable.
- Defensible résumé wording: *"Implemented and dual-simulator verified a
  parameterized HDM-style address-window decoder and HPA-to-DPA translator with
  overlap, alignment, overflow and capacity checks."* Not yet a full "CXL Type-3
  validation platform" — see `evidence/claims_matrix.csv`.
- Formal proof: properties written under `` `ifdef FORMAL ``; **BLOCKED** on sby install.

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
