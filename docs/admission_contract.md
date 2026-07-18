# M4 Phase 2b — Atomic Admission Datapath (`admission_top`)

`rtl/core/admission_top.sv` ties the verified `outstanding_tracker` and
`credit_manager` into one atomic admission datapath. Verified against an
independent integration model (`tb/models/admission_model.py`) that reuses the
tracker reference model plus a credit ledger and a one-entry issue buffer.

> **Scope.** The shared *global* configuration commit (HDM windows + capacity +
> timeout + credit maxima + epoch) is **deferred to Phase 2c**. Here the credit
> maxima are fixed at `RESET_MAX` and the active config epoch is a config-stable
> input captured on accept; no cfg commit occurs. No system-level epoch/config
> atomicity is claimed yet.

## Credit-vector layout (contract)
`CREDIT_VEC_W = N_POOLS*AMT_W`; pool `p` occupies `credit_vec[p*AMT_W +: AMT_W]`.
An elaboration check rejects `COUNT_W < AMT_W+1`. The tracker stores this vector
per entry (`CREDIT_W = CREDIT_VEC_W`); the ledger consumes/returns per pool.

## One authoritative admission event
`req_accept = req_valid && req_ready`, where `req_ready` depends **only** on
registered / config-stable conditions — `rst_n`, `req_accept_enable`, tracker
allocation readiness (`!full`, registered), credit consume readiness (a pure
function of the registered ledger + the request amount), and issue-buffer
readiness (registered). **No downstream *valid* feeds `ready`**; the one-entry
issue buffer uses `ready = !full` (registered), giving an intentional one-cycle
drain bubble rather than a combinational loop.

All allocation-side effects fire **iff** `req_accept` (proved by induction):
```
tracker_alloc_fire == req_accept
credit_consume_fire == req_accept
issue_enqueue      == req_accept
```
On that edge the entry captures the active `epoch`, `op`, `meta`, the exact
per-pool credit vector, and is tagged with the tracker's composite `{gen,slot}`.

## Credit return — same-edge, aggregated, never truncated
Credits return via the tracker's **combinational** commit sidebands (Phase 2a),
never via the registered informational `reclaim_rsp_*`. Per pool the retire and
reclaim commit vectors are added at **`RET_W = AMT_W+1`** *before* the ledger sees
them, so a same-cycle dual return to one pool cannot truncate. The
`credit_manager` return path is parameterized `RET_W` and widened to `AMT_W+1`
here. It is **backward-compatible under the default `RET_W=AMT_W`; the original M3
configurations were fully reverified** (credit sweep + `credit.sby` 3/3 +
`credit_matrix` 10/10 all still pass).

A valid retirement and a successful reclaim may fire the **same cycle on different
slots** (`r_slot ≠ rc_slot`, proved + covered); both vectors return. A same-slot
response/reclaim collision resolves to `SUPERSEDED` (reclaim is a no-op), so only
the retirement vector returns.

## Proved by induction (`formal/admission.sby`, bmc + prove + cover)
- **Conservation (the headline invariant):** for every pool,
  `credit_used[p] == Σ over live tracker entries of stored_credit[p]`. Quarantined
  (timed-out) entries remain **live** and stay in the sum; timeout alone returns
  no credit. The sum uses an **explicitly widened accumulator** `SUM_W = max(COUNT_W,
  AMT_W + $clog2(DEPTH+1)) + 1` that cannot wrap for the mathematical sum of every
  live entry, so this is **true equality — not equality modulo 2^COUNT_W**. Two
  companion asserts pin it down: the sum's bits above `COUNT_W` are **zero** (no
  hidden excess stored credit), and the sum is `<= configured_max`.
- **Epoch capture:** one cycle after `req_accept`, the allocated slot holds the
  **presented** active epoch (a wrong/mis-wired epoch is caught).
- One authoritative event (all three consumers fire together).
- **A2 as a DUT theorem:** `!req_accept_enable ⇒ !req_accept && !tracker_alloc_fire
  && !credit_consume_fire && !issue_enqueue`.
- Credit return is **never rejected** (`credit_return_valid ⇒ credit_return_accepted`).
- Sub-module invariants (occupancy = popcount(live); `used ≤ max`; the exact ledger
  delta; commit-sideband correctness) compile in as strengthening lemmas.
- Covers reached (non-vacuity): ordinary accept; alloc+retire same cycle;
  alloc+retire+reclaim; dual return; A2 gate active; admission blocked
  independently by tracker-full / credits / issue-buffer; reclaim backpressure;
  reset with live entries.

## Verification lanes
- **Differential sweep** — 4 configs `(N_POOLS,AMT_W,COUNT_W,RESET_MAX,DEPTH,GEN_W)`
  × 4000 cycles, two-toolchain cross-check (system Icarus 12.0 + Verilator 5.020
  **and** OSS CAD Suite Icarus 14.0 + Verilator 5.051), 0 errors. The independent
  model self-checks conservation and ledger bounds every cycle.
- **Formal** — `admission.sby` bmc + prove(induction) + cover PASS, 0 unreached.
  `admission_matrix.sby` = **five selected instances** — `DEPTH=1`; non-power-of-two
  `DEPTH=3`; three pools; `COUNT_W=AMT_W+1` boundary; a wider-`AMT_W` dual-return
  config — each run prove + cover: **10/10 tasks** (five instances, not a Cartesian
  product), reported separately from the tracker/credit matrices.
- **Sim mutation** — 29/29 killed incl. partial admission (consume ≠ accept), wrong
  epoch capture, truncated dual return, missing reclaim return.
- **Formal mutation** — 6 integration mutations killed on a `RESET_MAX > 2^AMT_W-1`
  config (so effects are reachable): partial admission, missing reclaim return,
  **narrowed dual-return accumulator** (modulo-wrap would hide a dual return),
  wrong pool slice, wrong epoch capture, and timeout freeing a credit-bearing slot.
- **XSim** — reduced third-engine cross-check PASS.
- **Clean clone** — exact-commit reproduction under `env -i`.

## Deferred to Phase 2c (still NOT_RUN)
One shared `cfg_commit_fire` for HDM windows / capacity / timeout / credit maxima /
epoch, committing only when admission is frozen, tracker occupancy and credit usage
are zero, and no accept/retire/reclaim can conflict. Until then the **system-level**
epoch/config-atomicity claim remains gated (Phase 2b proves only capture of the
*presented* active epoch at `req_accept`).
