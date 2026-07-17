# M3 Interface Contract — credit_manager

Parameterized multi-pool credit manager (`rtl/core/credit_manager.sv`) verified
against the independent model `tb/models/credit_model.py`. Credit accounting is
**ledger logic**: it never clamps, never partially updates, and never silently
tolerates an illegal return or a non-representable configuration.

## Flat ports (no packed-multidim at the interface)
All per-pool vectors are FLAT `[N_POOLS*W-1:0]`, sliced with `[p*W +: W]`. The
testbench composes each input in a temp and drives it with **one whole-vector
assignment per cycle**. A **walking-one port-mapping test** (each pool in turn)
confirms TB slicing and DUT indexing use the identical convention.

### Root-cause of the earlier cross-simulator divergence (isolated, not assumed)
An earlier packed-multidim credit interface diverged between Icarus and Verilator
for `N_POOLS ≥ 2`. An **A/B isolation** (identical packed-multidim port; only the
stimulus style varied: per-element `din[p]<=…` vs whole-vector `din<=…`) showed
**both** styles propagate correctly under Icarus 12.0 **and** Verilator 5.020
(0 errors) — so per-element *nonblocking* packed writes were **not** the cause.
The correct, defensible statement is therefore: *the failure was localized to the
packed multidimensional DUT/TB boundary (most plausibly DUT-side width evaluation
of the inline legality comparison); flattening that boundary and adding walking-one
lane checks eliminated the divergence across Icarus, Verilator and XSim.* No claim
is made that the testbench alone was at fault.

## Authoritative state
Stored: `used[p]`, `configured_max[p]`. Derived: `available[p] = configured_max[p]
− used[p]`. Invariant: `0 ≤ used[p] ≤ configured_max[p]`. **Functional state never
saturates, wraps or clamps**; diagnostic counters saturate.

## All-or-nothing, no bypass
A consume is legal only if **every** pool has room; a return only if **every** pool
holds ≥ the amount. Legality uses **registered pre-cycle state**, so credits
returned this cycle cannot enable a consume this cycle (no
`response→return→ready→request→response` combinational loop). Same-cycle legal
consume+return apply the exact widened net delta
`next_used = used + consume − return`; each is independently all-or-nothing.

## Configuration is an ATOMIC EVENT (not a droppable pulse)
`cfg_commit_fire` requires `config_commit && frozen_and_empty && all pools unused
&& every requested max representable`. On that edge, **consume and return are
blocked** (mutually exclusive with the commit). All pool maxima change together
or none. A refused commit is **observable**: `cfg_reject` pulse + `cfg_reason` +
saturating `cfg_reject_count`.

- The requested-max field is **`COUNT_W+1` bits** so a **non-representable** value
  (> `2^COUNT_W−1`) can be *expressed and rejected* — `cfg_reason = CFG_UNREP`.
  (A `COUNT_W`-wide field could not carry an out-of-range value; the earlier
  divergence was exactly this: the RTL truncated 8→0 while the model kept 8.)
  **This `COUNT_W+1` request field is the AUTHORITATIVE pre-truncation
  representation.** If any upstream logic truncates the requested maximum to
  `COUNT_W` bits *before* it reaches the credit manager, the original overflow is
  destroyed and `CFG_UNREP` can no longer detect it — the M4 integration must
  carry the full-width request all the way to this representability check.
- A busy/occupied/unfrozen refusal reports `cfg_reason = CFG_BUSY`.

## Reset contract
`used=0`, `configured_max=RESET_MAX`, `hwm=0`, sticky diagnostics cleared, and
**no `consume_fire`/`return_accepted`/`cfg_commit_fire`/`cfg_reject` pulse** (the
event outputs are gated on `rst_n`).

## Diagnostics
Saturating counters: consume-ok / consume-blocked / return-ok / return-illegal /
cfg-reject. Sticky first-error with **deterministic priority** (illegal return
outranks a config refusal), capturing first offending pool and amount.
`diagnostic_clear` clears diagnostics and restarts the watermark from the current
occupancy — it **never** affects the ledger (`used`/`configured_max`).

## Formally verified (bmc + induction + cover, `formal/credit.sby`)
`used ≤ configured_max`; `available == configured_max − used`; `hwm ≥ used`;
all-or-none consume/return; **exact widened net delta** (subsumes "illegal/blocked
op changes nothing" and "never clamps/saturates"); `cfg_commit_fire ⇒ no
consume/return`; commit⊕reject exclusivity; `consume_ready` is a pure function of
registered state (no bypass); deterministic first-error priority; `configured_max`
changes only on a legal commit.

**Formal parameter instances (exact tuples — not a Cartesian product):** five
instances `(N_POOLS,COUNT_W,AMT_W,RESET_MAX)` (DIAG_W=3 so saturation is reachable) = `(1,4,2,1) (2,4,2,3) (3,5,3,7)
(2,3,2,2) (2,6,3,4)`, each run `prove`(induction) and `cover` → **10/10 tasks**.
Cover reachability + formal-mutation (`cfg-needs-empty`, `net-delta`,
`cfg-blocks-consume`) demonstrate non-vacuity.

## M4 prerequisites (tracked, not yet done)
- **Global configuration atomicity:** M3's `cfg_commit_fire`/`cfg_reject` is a
  LOCAL disposition for standalone isolation. M4 must place all consumers (HDM,
  capacity, timeout, credit maxima, epoch) behind **one shared** accepted commit
  event (`cfg_commit_valid/ready/fire`), with the controller holding the request
  until every consumer is ready. Representability and quiescence must be resolved
  **before** the shared commit edge — a local reject must never leave the system
  partially configured.
- `A2` (`!req_accept_enable ⇒ !alloc_fire`) is an M2.1 **environment assumption**
  that M4 must replace with a **proved integration property** (`alloc_fire ==
  req_accept`, and `req_accept` includes `cfg_req_accept_enable`).
- The tracker's **reclaim** channel is still a 1-cycle request with a
  combinational class; M4 requires a **registered** `reclaim_req_valid/ready` +
  `reclaim_rsp_valid/ready/class` channel so recovery cannot depend on sampling a
  transient value.
