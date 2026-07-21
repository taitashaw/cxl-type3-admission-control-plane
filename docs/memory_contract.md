# M6 — Behavioral Memory Backend (`mem_backend`) + Memory Subsystem (`mem_subsys_top`)

The `rw_scheduler` (M5) issues transactions to an abstract tagged memory port. M6
provides that backend and the integrated datapath, and proves **end-to-end
read-after-write correctness**.

## `mem_backend.sv` — behavioral memory (DDR4 model, timing-abstracted)
- **Request in** (from scheduler `mem_*`): `req_valid/ready`, `req_tag`, `req_write`,
  `req_addr`, `req_wdata`. Accepted when the completion queue has room
  (`req_ready = rst_n && !cq_full`, registered state).
- **Completion out** (to scheduler `mc_*`): `cmp_valid`, `cmp_tag`, `cmp_rdata`. The
  scheduler always accepts a completion for an issued entry (no backpressure), so a
  valid completion is consumed every cycle it is presented.
- **Behavior:** one request/cycle, processed in **accept order**. A write updates
  `mem[addr]`; a read **captures** `mem[addr]` at accept. Each request enqueues a
  completion `{tag, rdata}` into a FIFO; the FIFO head is presented and popped.
- **Not modeled:** DRAM timing (tRCD/tRP/refresh/banks), burst framing, ECC. This is
  a *behavioral* functional model — a tagged, FIFO-ordered memory. No physical-DDR
  claim.

### Proved by induction (`formal/mem_backend.sby` + matrix)
- FIFO accounting: `cq_count ≤ CQ_DEPTH`; `req_ready == !cq_full`;
  `cmp_valid == (cq_count != 0)`; head/tail pointers stay in range and
  `count == (tail - head) mod CQ_DEPTH` sense (no lost/duplicated completion).
- Order/data preservation: a symbolic tracked completion exits in FIFO order with
  the tag and rdata it was enqueued with (no reorder, no corruption).
- A write updates `mem[addr]`; a read enqueues the pre-edge `mem[addr]`.
- Reset clears the queue; no `cmp_valid` during reset.

## `mem_subsys_top.sv` — scheduler + backend
Wires `rw_scheduler.mem_* ↔ mem_backend.req_*` and `mem_backend.cmp_* → scheduler.mc_*`.
External ports are the scheduler's issue (`iss_*`) and response (`rsp_*`) sides.

### End-to-end correctness (independent model + formal, tiny address space)
For any read transaction that produces a response, `rsp_rdata` equals the value of
the **most recent write to the same address that was accepted at the issue port
before this read** (or the reset value if none). This composes:
- the scheduler's **per-address program order** (a read cannot reach memory before an
  older same-address write completes), and
- the backend's **in-accept-order** application (same-address writes/reads reach the
  backend in program order, so a read sees the latest same-address write).

The independent model keeps a **shadow memory** (updated on each write's issue
accept) and a per-tag **expected read value**; every read response is checked
against the shadow each cycle in the two-toolchain differential.

Formal proves the same property by **unbounded k-induction** (not BMC, not
simulation) in `formal/mem_subsys.sby`, using a symbolic address `f_addr` and the
module's flat debug/observation ports (no cross-module array index, which would
create a floating Yosys autowire). The strengthening invariant is:
- **M** — memory reflects the last write to `f_addr` processed by the backend;
- **INV-S** — with no pending (accepted-not-applied) write to `f_addr`, memory
  equals `shadow` (the last write to `f_addr` accepted at the issue port);
- **R0/R1** — a not-done read's per-tag expected value equals memory (no pending
  older write) or the youngest pending older write's data;
- **I4** — a done read carries its expected value;
- **INV-CQ** — a pending completion sitting in the backend FIFO that belongs to a
  read to `f_addr` (matched by its unique tag) carries that read's expected value,
  which links the read's captured value *through* the FIFO to its delivery.
This rests on the backend's **FIFO structural-consistency** invariant
(`tail == (head+cnt) mod CQ_DEPTH`) and a **unique-live-tag** environment
constraint (guaranteed upstream by the tracker/admission layer, enforced here as an
input constraint). No BMC or simulation fallback is used for this safety property.
Non-vacuity is shown by three end-to-end mutations (read-returns-zero,
completion-drops-data, drop-hazard-interlock) that this proof kills but the
component (`mem_backend` / `rw_scheduler`) proofs alone do not.

## Verification lanes
Two-toolchain differential (system Icarus 12.0 + Verilator 5.020 and OSS CAD Suite
14.0 + Verilator 5.051) for both `mem_backend` and `mem_subsys_top`; SymbiYosys
bmc + induction + cover, five-instance matrices; sim + formal mutation non-vacuity;
XSim third engine; exact-commit clean-clone. **Safety only** — no liveness/fairness,
no DRAM-timing, no memory-consistency claim beyond the stated per-address ordering.
