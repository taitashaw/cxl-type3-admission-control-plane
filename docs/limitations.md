# Limitations & Blocked Lanes — honest status

This platform separates result classes strictly. Nothing below is claimed beyond
what a raw log in `evidence/` supports.

## Result-class ledger (as of current milestone)

| Class | Status | Evidence |
|---|---|---|
| RTL_SIMULATED | ✅ present | `evidence/raw/{icarus,verilator}_tb_hdm_decode_run.log` — 15/15, both engines |
| SOFTWARE_EMULATED (QEMU) | ◻ not run yet | QEMU 8.2.2 supports `cxl-type3`; lane not yet built |
| SYNTHESIZED | ◻ not run | AMD portable synth optional; Agilex synth needs Quartus |
| TIMING_ANALYZED | ⛔ BLOCKED | requires Quartus STA (not installed) |
| FPGA_MEASURED | ⛔ BLOCKED | no CXL device / FPGA on host |
| BLOCKED | documented | see below |
| NOT_RUN | tracked | remaining Phase 1–7 tasks |

## Hard BLOCKED lanes on this host (evidence-backed)

1. **Altera Quartus / Agilex 7 R-Tile build** — `quartus*`, `qsys*`, `jtagconfig`
   all MISSING; no `intelFPGA*`/`altera*` install root. No CXL IP present.
   → No synthesis, fitting, STA, `.sof`, or SignalTap possible here.
2. **Hardware bring-up** — `/sys/bus/cxl` ABSENT, no `cxl_*` kernel modules,
   `lspci` shows zero CXL devices (only two NVMe SSDs). No FPGA/JTAG endpoint.
   → No enumeration, link speed/width, AER, or bandwidth measurements possible.
3. **Physical SERDES characterization** — `PHYSICAL_SERDES_CHARACTERIZATION = BLOCKED`
   (no Transceiver Toolkit, no device, no eye/BER/margining capability).

These are not failures of the project; they are environment constraints. Every
independent FREE-lane task continues regardless.

## Tool caveats found (real)

- **Verilator 5.020** is below the 5.036 recommended for *current* cocotb. The
  default regression uses native SV testbenches (no cocotb dependency) and runs
  today. cocotb can be added via the venv bootstrap when needed.
- **Verilator `-j 0` threadpool abort**: `--binary -j 0` can abort at process
  exit with "attempted to destroy locked Thread Pool" *after* a successful
  build. The runner (`scripts/run_sv_test.sh`) builds single-threaded to avoid it.
- **Verilator `--timing` packed-array-element scheduling quirk** (found &
  reproduced in this project): a *procedural blocking write to an individual
  element* of a packed multidimensional array, read through a module port by
  combinational logic, is **not** re-propagated on subsequent `#delay` steps
  (Icarus propagates it correctly). Minimal reproducer confirmed the divergence.
  Mitigation adopted: testbench stimulus holds per-window config in **scalar**
  regs concatenated into the packed ports via continuous assign — both engines
  then agree. This is also closer to how a real CSR block drives the ports.
  This quirk affects *testbench stimulus style only*; synthesizable RTL is
  unaffected.

## Not-yet-claimed (deliberately)

No claim is made anywhere in this repo about: PCIe Gen5 link-up, CXL.mem
enumeration, Type-3 compliance, 32 GT/s SerDes, negotiated x16, eye/BER,
measured bandwidth/latency, Quartus timing closure, DDR4 operation, or
SignalTap capture. Those require raw reports/lab logs that do not exist yet.
