# Limitations & Blocked Lanes — honest status

This platform separates result classes strictly. Nothing below is claimed beyond
what a raw log in `evidence/` supports.

## Result-class ledger (as of current milestone)

| Class | Status | Evidence |
|---|---|---|
| RTL_SIMULATED | ✅ present | hardened M1: ~29k differential checks/engine (Icarus+Verilator) across 1/2/4/8 windows + XSim reduced cross-check; 5/5 mutations killed |
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

## Issue classification (corrected)

The M1 bring-up surfaced three distinct issues. They are **not** all design bugs:

1. **Logic defect (design bug)** — the translator emitted stale error flags on a
   decoder miss. Fixed by gating all translation outputs on a match.
2. **RTL portability issue** — the original overlap logic (runtime-indexed
   `always_comb` over unpacked arrays) evaluated inconsistently across
   simulators. Reworked into constant-index generate logic; both engines + XSim
   now agree. This is a coding-style portability problem, not a wrong algorithm.
3. **Verilator-5.020 testbench/scheduling incompatibility (NOT a confirmed tool
   defect)** — see next section.

## Verilator packed-array stimulus incompatibility — characterization

Observed on **Verilator 5.020 only**: a *procedural blocking write to an
individual element* of a packed multidimensional array, read through a module
port by combinational logic, was not re-propagated on subsequent `#delay` steps
in the original combinational-stimulus testbench (Icarus propagated it). A
minimal reproducer is in the scratch history.

**Resolution / honest status:** this is called a *Verilator-5.020 packed-array
stimulus incompatibility observed in the original testbench*, **not** a confirmed
upstream Verilator defect. Verilator could not be upgraded on this host to
re-test (apt caps at 5.020; a source build needs flex/bison/autoconf, which are
absent and require sudo). Instead the reviewer-recommended discriminating test
was run: the hardened testbenches now drive configuration **synchronously**
(clocked register writes, sampled after the settling edge). Under synchronous
drive **all engines — Icarus 12.0, Verilator 5.020, and AMD XSim 2025.2 — agree
across the full 1/2/4/8-window sweep**, which indicates the original divergence
was tied to combinational blocking-write stimulus style, not the RTL and not a
proven simulator bug. Confirming an upstream defect would require a current
Verilator (≥5.036) and, if it persists, an upstream issue filing.

- **Verilator `-j 0` threadpool abort**: `--binary -j 0` can abort at process
  exit with "attempted to destroy locked Thread Pool" after a successful build.
  Runners build single-threaded to avoid it.
- **Verilator 5.020 < 5.036** recommended for *current* cocotb. The regression
  uses native SV testbenches (no cocotb dependency) and runs today.

## Formal verification status

`` `ifdef FORMAL `` properties are written into the RTL (containment, one-hot
classification, no-underflow). **Unbounded formal proof is BLOCKED** on this
host: SymbiYosys/yosys are not installed (yosys is apt-installable but requires
sudo, not run without approval). The same invariants are checked every vector in
simulation at the settled sample point, and are mutation-tested
(`scripts/run_mutation_tests.sh`). Do not read bounded simulation as formal proof.

## Not-yet-claimed (deliberately)

No claim is made anywhere in this repo about: PCIe Gen5 link-up, CXL.mem
enumeration, Type-3 compliance, 32 GT/s SerDes, negotiated x16, eye/BER,
measured bandwidth/latency, Quartus timing closure, DDR4 operation, or
SignalTap capture. Those require raw reports/lab logs that do not exist yet.
