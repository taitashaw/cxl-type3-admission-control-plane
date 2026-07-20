# M5 — Read/Write Scheduler (`rw_scheduler`) Contract

`rtl/core/rw_scheduler.sv` sits **after** the admission control plane: it accepts
admitted transactions, schedules them to an abstract memory backend, and returns a
tagged response for the tracker to retire. Verified against an independent Python
model (`tb/models/scheduler_model.py`).

## Interfaces
- **Issue in** (from admission downstream): `iss_valid/ready`, `iss_tag[TAG_W]`,
  `iss_write`, `iss_addr[ADDR_W]`, `iss_wdata[DATA_W]`. Accepted when a pending slot
  is free (`iss_ready = !full`, registered state — no downstream valid→ready path).
- **Memory out**: `mem_valid/ready`, `mem_tag`, `mem_write`, `mem_addr`, `mem_wdata`.
- **Memory completion in**: `mc_valid`, `mc_tag`, `mc_rdata`. Environment assumption:
  a completion targets exactly one **issued, not-yet-done** entry.
- **Response out** (to tracker retire): `rsp_valid/ready`, `rsp_tag`, `rsp_rdata`.

## Scheduling model (design decision)
A bounded pending table of `DEPTH` entries. Cross-address **reordering is allowed**;
per-address **program order is preserved** by a hazard interlock. This is the
standard memory-scheduler correctness model — it captures RAW/WAW/WAR without a
data-forwarding path (a younger same-address access cannot issue to memory until
every older same-address access has **completed**). Program order between entries is
tracked by an **age matrix** `older[i][j]` (i older than j), maintained on accept
and cleared on free — no wrapping sequence numbers.

- **Eligibility:** entry `i` may issue iff `valid[i] && !issued[i]` and there is **no**
  older, same-address, not-yet-`done` entry. Among eligible entries the lowest index
  is issued (selection is free once eligibility enforces order).
- **Completion:** `mc_valid` marks the matching issued entry `done` and latches
  `mc_rdata`.
- **Response:** the lowest-index `done` entry is presented; on `rsp_ready` it is freed.
  Responses may be out of order (the tracker is tag-matched).

## Proved by induction (`formal/scheduler.sby` + matrix)
- **Age matrix is a strict total order** over live entries: `older[i][i]==0`, and for
  distinct live `i,j` exactly one of `older[i][j]`/`older[j][i]` holds (the key
  inductive lemma).
- **Per-address order preserved:** for any two live entries `i` (older) and `j`
  (younger) with the same address, `j.issued ⇒ i.done` — a younger same-address
  access never reaches memory before the older one completes.
- **A memory issue is eligible:** when `mem_valid` picks entry `i`, no older
  same-address entry is un-`done`.
- **Accounting / no loss or duplication:** `Σ valid ≤ DEPTH`; `iss_ready == !full`;
  an entry is issued at most once and freed at most once per acceptance; a response
  is presented only for a live `done` entry (no response without an accepted
  transaction; no duplicate response for one acceptance).
- **Integrity:** `rsp_tag`/`mem_tag` equal the selected entry's stored tag; a `done`
  entry's `rdata` equals the completion data that marked it done.
- **Reset:** clears the table; no `mem_valid`/`rsp_valid`/side effect during reset.

## Verification lanes (planned, to match prior blocks)
Two-toolchain differential sweep (system Icarus 12.0 + Verilator 5.020 and OSS CAD
Suite 14.0 + Verilator 5.051), SymbiYosys bmc + induction + cover, a five-instance
formal matrix (DEPTH/width variations, incl. DEPTH=1 and non-power-of-two), sim +
formal mutation non-vacuity, XSim third-engine, exact-commit clean-clone.

## Honest scope
Safety only — **no liveness/fairness** claim (a stream of same-address accesses can
starve a blocked entry until completions arrive; forward progress depends on the
memory backend completing). Reordering **policy** here is lowest-eligible-index; a
reads-first / write-drain policy is a future refinement and does not affect the
proved ordering/no-loss safety. No memory-consistency-model claim beyond the stated
per-address ordering; no timing/DRAM-controller behavior is modeled (the backend is
an abstract tagged valid/ready completion port).
