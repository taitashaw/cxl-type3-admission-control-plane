# Environment Inventory — Project 2 (CXL Type-3 Validation Platform)

Generated from real, read-only probes on the build host. Regenerate the machine
form with `bash scripts/inventory_tools.sh` (writes `evidence/environment_inventory.json`).

- Host: `Linux 6.17.0-35-generic`, Ubuntu 24.04.4 LTS
- Working tree: `/home/jotshawlinux/Downloads/project2_cxl_validation` (not yet a git repo)

## Tool matrix

| tool | discovered path | version | licence | purpose | required lane | status |
|---|---|---|---|---|---|---|
| verilator | /usr/bin/verilator | 5.020 | free | primary RTL sim | FREE-sim | FOUND_AND_RUNNABLE ⚠ |
| iverilog | /usr/bin/iverilog | 12.0 | free | second RTL sim | FREE-sim | FOUND_AND_RUNNABLE |
| gtkwave | /usr/bin/gtkwave | 3.3.116 | free | waveform view | FREE-sim | FOUND_AND_RUNNABLE |
| python3 | /usr/bin/python3 | 3.12.3 | free | tooling/cocotb | FREE-sim | FOUND_AND_RUNNABLE |
| pytest | ~/.local/bin/pytest | 9.0.2 | free | test harness | FREE-sim | FOUND_AND_RUNNABLE |
| cocotb | — | — | free | cocotb lane | FREE-sim | MISSING (venv bootstrap) |
| qemu-system-x86_64 | /usr/bin/qemu-system-x86_64 | 8.2.2 | free | CXL Type-3 SW lane | FREE-qemu | FOUND_AND_RUNNABLE — advertises `cxl-type3` |
| gcc/g++/make/jq/numactl/perf/trace-cmd/bpftrace | /usr/bin/* | — | free | build/host tooling | FREE | FOUND_AND_RUNNABLE |
| vivado / xvlog / xelab / xsim | /tools/Xilinx/2025.2/Vivado/bin | 2025.2 | AMD (unverified) | XSim cross-sim, AMD_PORTABLE_SYNTHESIS | AMD | FOUND — licence not yet checked |
| vitis / xsct | — | — | AMD | (not required) | AMD | MISSING / NOT_REQUIRED |
| yosys / sby / z3 / boolector | — | — | free | formal lane | FREE-formal | MISSING (bootstrap) |
| verible / slang | — | — | free | lint/parse | FREE-lint | MISSING (bootstrap) |
| ndctl / cxl / daxctl / fio | — | — | free | QEMU-guest tools | FREE-qemu | MISSING (guest install) |
| quartus* / qsys* / jtagconfig | — | — | Altera | Agilex R-Tile build | LICENSED | **MISSING** |
| vsim / vcs / xrun | — | — | commercial | (not required) | COMMERCIAL | MISSING / NOT_REQUIRED |

⚠ Verilator 5.020 is below the 5.036 recommended for *current* cocotb. Native
Verilator/Icarus SystemVerilog testbenches (the default regression path here) do
not depend on cocotb and run today. See also the documented Verilator `--timing`
packed-array quirk in `docs/limitations.md`.

## Host CXL capability (read-only)

- `/sys/bus/cxl`: **ABSENT** — no kernel CXL bus.
- CXL kernel modules: **none loaded**.
- `lspci` CXL devices: **0** (only two SK hynix NVMe SSDs present).
- No FPGA/JTAG endpoint visible.

→ **Hardware bring-up, SerDes characterization, and Quartus/R-Tile lanes are BLOCKED**
on this host (no tools, no device). Classified with evidence, not assumed.

## Two-lane execution reality

| Lane | Status | Basis |
|---|---|---|
| FREE — RTL simulation (Verilator + Icarus) | ✅ ACTIVE | M1 passes 14/14 on both engines |
| FREE — QEMU CXL Type-3 system tests | ✅ VIABLE | QEMU 8.2.2 exposes `cxl-type3`, `pxb-cxl`, `cxl-rp` |
| FREE — formal / lint | ◻ PENDING | yosys/sby/verible need bootstrap |
| AMD portable (XSim / synth) | ◻ CONDITIONAL | Vivado present; licence unverified; never Agilex |
| LICENSED — Quartus / R-Tile | ⛔ BLOCKED | Quartus not installed |
| HARDWARE — board bring-up | ⛔ BLOCKED | no CXL device / FPGA on host |
