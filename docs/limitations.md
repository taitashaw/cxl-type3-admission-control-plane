# Limitations & Blocked Lanes — honest status

This platform separates result classes strictly. Nothing below is claimed beyond
what a raw log in `evidence/` supports.

## Result-class ledger (as of current milestone)

| Class | Status | Evidence |
|---|---|---|
| RTL_SIMULATED | ✅ present | hardened M1: ~30k differential checks/engine (Icarus+Verilator) across 1/2/4/8 windows + XSim reduced cross-check; 6/6 mutations killed |
| FORMAL_PROVEN | ✅ present | SymbiYosys bmc+induction: decoder/translator + config FSM safety proofs (`evidence/raw/formal_*.log`) |
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

**Resolution / honest status (precise):** *The discrepancy was isolated to
asynchronous packed-array testbench stimulus under Verilator 5.020. Synchronous
registered stimulus eliminated it across three simulators (Icarus 12.0,
Verilator 5.020, AMD XSim 2025.2); no simulator defect is claimed.* Synchronous
driving demonstrated a portable workaround — it did not prove Verilator 5.020 is
defect-free. Confirming or excluding an upstream defect would require a current
Verilator (≥5.036) and, if it persisted, an upstream issue filing.

- **Verilator `-j 0` threadpool abort**: `--binary -j 0` can abort at process
  exit with "attempted to destroy locked Thread Pool" after a successful build.
  Runners build single-threaded to avoid it.
- **Verilator 5.020 < 5.036** recommended for *current* cocotb. The regression
  uses native SV testbenches (no cocotb dependency) and runs today.

## Formal verification status — AVAILABLE and PASSING

Formal is **not** blocked. A pinned **OSS CAD Suite** (Yosys 0.67 + SymbiYosys +
solvers) is installed rootlessly under `tools/` via
`scripts/bootstrap_formal.sh` (download → SHA-256 verify → extract, no sudo).
`make formal` runs two SymbiYosys suites, each with a bounded model check (`bmc`)
and an **unbounded** safety proof (`prove`/induction):

- `formal/decode.sby` — decoder + translator: accept ⇒ exactly one match,
  overlap ⇒ ¬accept, accept ⇒ aligned, accept ⇒ full 64B line in window,
  accept ⇒ ¬underflow ∧ ¬overflow ∧ ¬oob, accept ⇒ DPA = dpa_base+(hpa−base),
  and one-hot classification. **PASS** (bmc + induction).
- `formal/config.sby` — config FSM: epoch increments exactly once per commit,
  active config changes only on commit (atomic), commit only from COMMIT state,
  FREEZE→COMMIT only when `outstanding_cnt==0` (drain-before-commit),
  `traffic_freeze ⇒ ¬req_accept_enable`. **PASS** (bmc + induction).

Evidence: `evidence/raw/formal_{decode,config}.log`, `formal_mutation.log`.

**Non-vacuity is demonstrated, not assumed:**
- Each suite has a `cover` task; all cover statements are reachable (valid
  accept, miss, overlap reject, unaligned reject, HPA line-cross, DPA
  capacity-cross, invalid-config reject, ACTIVE→FREEZE→DRAIN→COMMIT→ACTIVE,
  DRAIN with `outstanding_cnt>0`, concurrent update+admission, reset from each
  FSM state). `make formal` fails if any cover is unreachable.
- A **formal-mutation** pass (`scripts/run_formal_mutation.sh`) breaks each
  protection in turn and confirms the relevant proof now **fails** (5/5). Sim
  mutation and formal mutation catch different weaknesses; both are run.

**Explicit formal assumptions (config):**
- `initial assume(!rst_n)` — a defined start in reset; `rst_n` is **free**
  thereafter, so it may deassert (required for the useful covers) and re-assert
  (required for reset-from-each-state covers). Reset is not held.
- `sh_*`, `cfg_update_req`, `outstanding_cnt` are **fully free** every cycle —
  `outstanding_cnt` may rise, stay nonzero, and return to zero; no input is
  constrained to force the asserted behavior, and `req_accept_enable` is an
  output (never assumed).
- Temporal asserts are gated on `rst_n && f_init` so they are not evaluated
  across the reset boundary; they are otherwise unconstrained.

**Scope caveats:** the free-Yosys frontend has a limited SV subset, so harnesses
use manual state/counter registers, not SVA `$past`/`property`. These are
**safety** proofs (bmc + induction) — no liveness/Tabby-grade claims. In
particular, drain **liveness** (that `outstanding_cnt` eventually reaches 0) is
NOT proved here — a never-draining datapath leaves the FSM frozen; the M2
outstanding-tracker timeout is what forces progress.

## Not-yet-claimed (deliberately)

No claim is made anywhere in this repo about: PCIe Gen5 link-up, CXL.mem
enumeration, Type-3 compliance, 32 GT/s SerDes, negotiated x16, eye/BER,
measured bandwidth/latency, Quartus timing closure, DDR4 operation, or
SignalTap capture. Those require raw reports/lab logs that do not exist yet.

## M4 admission control plane — verified scope and honest limits (Phase 2c complete)

**Verified (RTL_SIMULATED + FORMAL, documented parameter instances):** the admission
control plane — outstanding tracker, multi-pool credit manager, registered reclaim,
atomic admission (`req_accept` drives alloc + consume + issue together), credit
**conservation** proved by induction as mathematical equality, and **one atomic
global configuration commit** (HDM/capacity/timeout/credit-maxima/epoch) after
freeze + full drain. Two-toolchain differential + XSim + SymbiYosys bmc/induction/
cover + five-instance matrices + sim/formal mutation non-vacuity. See
`docs/config_contract.md` and `evidence/claims_matrix.csv`.

**NOT claimed / honest limits:**
- **No general liveness.** Only *safety* is proved. Config drain can remain blocked
  indefinitely by a non-responding transaction, a quarantined entry that is never
  reclaimed, a stalled issue buffer, or a requester that never completes recovery.
- **Formal is per-instance,** not a universal parameter proof (five documented
  tuples per block, each prove+cover).
- **HDM address *decode*** is the separately verified M1 block; Phase 2c carries and
  commits the HDM/capacity fields atomically as configuration words but does not
  re-derive decode inside the control plane.
- Unchanged blocked lanes below (Quartus STA, FPGA bring-up, CXL device) still
  apply: no synthesis, timing closure, silicon, PCIe bandwidth or tapeout is claimed.
