# M2 Interface Contract — outstanding_tracker

Parameterized outstanding-transaction tracker (`rtl/core/outstanding_tracker.sv`)
verified against the independent model `tb/models/tracker_model.py`.

## Composite tags — {generation, slot}

The externally returned tag is **`{generation, slot}`**, never a bare slot. After
a slot is retired and reused, a delayed response for the previous occupant would
be indistinguishable from the new transaction if only the slot were returned. The
**generation** is bumped on every (re)allocation of a slot; a response retires an
entry only if **both** slot and generation match a live entry.

- `SLOT_W = (DEPTH<=1) ? 1 : $clog2(DEPTH)`; `TAG_W = GEN_W + SLOT_W`.
- Tag layout: `tag = (generation << SLOT_W) | slot`.

## Per-slot storage
`live`, `generation`, `epoch` (captured at allocation), `op`, `meta`,
`issue_ts`, `timed_out`.

## Allocation
Accepted (`alloc_gnt`) only when `alloc_req` and a free slot exists (`!full`).
Deterministic lowest-index free slot. On grant: generation bumped, `alloc_tag`
returns the **new** generation, and epoch/op/meta/issue_ts stored atomically;
occupancy +1. `full` ⇔ `occupancy == DEPTH`.

## Retirement / response classification
`resp_tag` decodes to `{r_gen, r_slot}`:

| class | condition |
|---|---|
| `INVALID_SLOT` | `r_slot >= DEPTH` |
| `NON_LIVE` | slot not live |
| `STALE_GEN` | live but `r_gen != generation[slot]` |
| `VALID` | live and generation matches → retire |

Stored metadata is read **before** the entry is cleared. Only `VALID` retires
(clears live, occupancy −1). Each class has a counter; the first bad-response
class is captured in a sticky `err_first_class`.

## Same-cycle event priority (explicit contract)

| simultaneous events on ONE slot | required result |
|---|---|
| reset + anything | **reset wins** (all live cleared, no partial commit) |
| valid response + timeout threshold | **response retires; no timeout marking** |
| valid response + reclaim | **response wins; reclaim rejected** |
| reclaim + timeout discovery | reclaim only if the slot was **already quarantined before this cycle** |
| allocation + retirement | both allowed; **no same-cycle reuse** of the retiring slot |
| allocation + reclaim | reclaimed slot becomes allocatable **next** cycle |
| stale/invalid response + anything | **diagnostic only**; no live-state change |

Timeout qualification is exactly:
```
live && !timed_out && timeout_active && age_expired
     && !valid_retire_this_cycle(slot) && !valid_reclaim_this_cycle(slot)
```
This is formalized (asserted), not left to statement ordering. Occupancy delta ∈
{+1, 0, −1, −2}. Retiring metadata is read before any write to that slot.

## Timeout contract (hard)
- A **legal** threshold is `0` (⇒ timeouts **disabled**) or `0 < t < 2^(TS_W−1)`
  (so modulo age is unambiguous).
- An **illegal** (nonzero, out-of-range) threshold is **REJECTED at the boundary**:
  it is *not latched*, `active_thresh` keeps its previous legal value, and sticky
  **`timeout_cfg_bad`** is raised. It is **not** silently reinterpreted as
  "disabled" (which could freeze the tracker indefinitely).
- **Mutability contract: the threshold is latched ONLY while the tracker is EMPTY**
  (`occupancy == 0`). An administrative write can therefore never instantly time
  out already-live traffic, and no per-entry threshold storage is needed. Live
  entries always age against the threshold in force when they were issued.
- `age = (current_ts − issue_ts) mod 2^TS_W`, using the entry's original `issue_ts`.
- A timed-out entry is **quarantined**: flagged, counted, and **kept live** — its
  slot is never silently freed, so a late response cannot alias a new
  transaction. Timestamp wrap during quarantine does not free the entry.
- **All diagnostic counters SATURATE** (never wrap).

## Recovery ownership (reclaim)
`reclaim` is the recovery authority for quarantined entries:
- A successful reclaim (internal `reclaim_done`) requires `live && timed_out`
  (already quarantined **before** this cycle) and no same-cycle valid response to
  that slot.
- Reclaim carries the **full composite tag** `reclaim_tag = {generation, slot}` —
  a slot-only reclaim could free a *newer* occupant if the requester acted on
  stale state. Reclaim succeeds only when
  `slot < DEPTH && live[slot] && timed_out[slot] && generation[slot] == reclaim_generation`.
- Observable result `reclaim_rsp_class`:

  | class | meaning |
  |---|---|
  | `RCL_OK` | slot freed |
  | `RCL_INVALID_SLOT` | slot ≥ DEPTH |
  | `RCL_NOT_LIVE` | slot not live |
  | `RCL_STALE_GEN` | generation mismatch (requester used stale state) |
  | `RCL_NOT_QUARANTINED` | live+matching but not timed out — reclaim refused |
  | `RCL_SUPERSEDED` | a valid response retired the slot this cycle (response wins) |

  **Registered request/response handshake (M4 Phase 1).** Reclaim is a decoupled
  channel, not a combinational pulse:
  - `reclaim_req_valid` / `reclaim_req_ready` accept a request; `reclaim_req_ready
    = rst_n && !reclaim_rsp_valid` (one classification in flight at a time).
  - `reclaim_accept = reclaim_req_valid && reclaim_req_ready`. On accept the class
    is computed **combinationally from pre-edge state** (so a same-cycle valid
    response's freeing of the slot does **not** change the classification) and is
    **registered** into `reclaim_rsp_class`, with the freed slot's stored meta into
    `reclaim_rsp_meta` on `RCL_OK`.
  - `reclaim_rsp_valid` / `reclaim_rsp_ready` return the result; the response is
    **held stable under backpressure** (`!reclaim_rsp_ready`) until consumed —
    verified formally (`reclaim_rsp_valid`/`class`/`meta` invariant while waiting)
    and by cover. Recovery therefore never depends on sampling a transient value.
  - The classification priority is `INVALID_SLOT > NOT_LIVE > STALE_GEN >
    NOT_QUARANTINED > SUPERSEDED > OK` — identical between RTL and the independent
    model, and to the response-path classifier.
- A reclaimed slot is freed; the **next allocation bumps its generation**, so a
  later response to the old transaction is `NON_LIVE` (before realloc) or
  `STALE_GEN` (after). **Qualification:** a late response after reclaim cannot
  retire a new transaction **unless that slot's generation field has wrapped**;
  production safety therefore requires a generation width and a bounded response
  lifetime that prevent such aliasing (see *Generation-wrap bound* below).
- Authority is whoever drives `reclaim_req_valid` (software / recovery FSM). Reset
  is the bulk alternative: it invalidates every live entry.
- `quarantined_count` (current live+timed_out) and `reclaim_count` are exposed so
  a system can detect and bound quarantine accumulation.

## Per-slot vs global priority (explicit)
The priority order is **per slot**, not global. Independent operations on
*different* slots proceed in the same cycle:
- **Global**: only `reset` (clears everything).
- **Per-slot**: response > reclaim > timeout-marking > allocation, applied to
  that slot's state only.
- **Independent**: a valid response retiring slot *i* never suppresses an
  allocation into a different free slot *j* (`alloc_gnt` depends only on
  `alloc_req && have_free && !full`). Because allocation targets a *free* slot and
  a response targets a *live* slot, they are necessarily different slots — the
  `alloc_gnt && resp_retire` cover (DEPTH>1) demonstrates this concurrency.
- **Aggregate**: occupancy/counter deltas are computed *after* all per-slot
  decisions (`occ_next = occ + alloc − retire − reclaim`).

## Counters / status
occupancy, high-watermark, **quarantined_count**, alloc/retire/full/timeout/
**reclaim**/invalid-slot/non-live/stale-generation counts (**saturating**),
`timeout_any`, `timeout_cfg_bad`, sticky first-error class.

## Formal parameter instances (exact tuples proved)

One `.sby` instance does **not** prove all parameter values. Safety properties
were **formally verified for the documented parameter instances** below —
**five selected tuples, each run as `prove`/induction and `cover` = 10 tasks**.
This is a *selected set*, **not** a Cartesian product of the listed values:

| instance | DEPTH | GEN_W | TS_W | rationale |
|---|---|---|---|---|
| `d1`    | 1 | 1 | 3 | DEPTH=1 edge (no same-cycle reuse possible) |
| `d3np`  | 3 | 2 | 4 | non-power-of-two depth |
| `d4pow` | 4 | 1 | 3 | power-of-two depth + gen wrap + ts wrap |
| `gwrap` | 2 | 1 | 4 | generation wraps fast (GEN_W=1) |
| `twrap` | 7 | 2 | 3 | non-power-of-two + small TS_W (timestamp wrap) |

Plus the default instance (`formal/tracker.sby`, DEPTH=3/GEN_W=2/TS_W=4) with
bmc + induction + cover.

> **Precise phrasing:** *five documented parameter instances; 10/10 prove/cover
> tasks passed* (plus 3/3 default-instance tasks). Never state "10/10 parameter
> instances" — there are five instances, each run in two modes. This is not a
> universal proof over all parameter values.

Note: the *simultaneous alloc+retire* cover is guarded to `DEPTH>1` — with a
single slot it is genuinely unreachable (a retiring slot is not reusable the same
cycle, by design), which the matrix surfaced.

## Formally verified (bmc + induction, `formal/tracker.sby`)
`occupancy == popcount(live)`; `occupancy <= DEPTH`; `high_watermark >= occupancy`;
occupancy delta bounded (+1/−2); a `VALID` retire requires a live entry with
matching generation; only `VALID` responses retire; a grant implies `!full`;
`full ⇔ occupancy==DEPTH`; live-entry metadata stable until reallocation (slot-0
witness); `timeout_count` advances by exactly the number of newly-timed-out slots.
Cover tasks prove reachability of alloc / full / retire / simultaneous
alloc+retire / stale response / timeout / reset-with-live. Formal-mutation
confirms these proofs fail when the generation check, generation bump, or timeout
aggregate is broken.

## Explicit caveats (per review)
- **Duplicate detection:** no retired-tag history is kept, so a duplicate late
  response after retirement is classified `NON_LIVE` (or `STALE_GEN` after the
  slot is reallocated), **not** a distinct `DUPLICATE`. A distinct duplicate
  class would require bounded retired-tag history. No duplicate-detection claim
  is made.
- **Generation-wrap bound:** stale detection — and the "a late response cannot
  retire a new transaction" guarantee — hold **only while fewer than `2^GEN_W`
  reallocations of a given slot occur while a stale response for it is still in
  flight**. Beyond that the generation aliases and an old response could match a
  new occupant. Production configuration should therefore use **`GEN_W = 16`**
  unless interface width forbids it, together with a bounded response lifetime
  (timeout + quarantine) that makes wrap-around aliasing impossible.
  The formal instances deliberately use tiny `GEN_W` (1–2) to *exercise* wrap;
  they do not imply small `GEN_W` is safe in production.
- **Vendor-adapter caveat:** the project-owned interface returns the full
  `{generation, slot}` tag. If a vendor IP boundary returns fewer tag bits, the
  adapter must either preserve the generation in an internal mapping table, or
  enforce a quarantine/reuse policy that guarantees old responses cannot alias.
  The tracker alone cannot fix a boundary that discards generation information.
- **Liveness (not proved):** eventual retirement is a liveness property requiring
  environmental assumptions about response delivery; only **safety** is proved
  here. A response that never arrives leaves the slot occupied until `reclaim` or
  reset.

## Deferred to integration (not yet claimed)
The tracker stores and returns an epoch per tag, but the end-to-end statement
*"each accepted request captures the configuration epoch"* requires wiring
`hdm_config.cfg_epoch → outstanding_tracker.alloc_epoch` and checking it at
retirement. That integration is the next step; the mechanism (epoch stored per
tag, composite-tag uniqueness) is proved here.
