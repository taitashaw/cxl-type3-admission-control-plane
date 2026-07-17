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

## Same-cycle allocate + retire
Supported. Occupancy delta ∈ {+1, 0, −1, −2}. The free slot chosen for
allocation is guaranteed distinct from a same-cycle retiring/reclaimed slot
(those are still live this cycle — **no forwarding**), so a freed slot becomes
allocatable only on the *next* cycle. Reads of retiring metadata precede any
write to that slot.

## Timeout — QUARANTINE + REPORT
`age = (current_ts − issue_ts) mod 2^TS_W`; timeout when `age >= timeout_thresh`
(require `timeout_thresh < 2^(TS_W−1)`). A timed-out entry is flagged sticky and
counted but **stays live** — its slot is never silently freed, so a late response
cannot alias a new transaction. An explicit `reclaim` frees a slot; the next
allocation bumps its generation, so any later response is `STALE_GEN`/`NON_LIVE`.

## Counters / status
occupancy, high-watermark, alloc/retire/full/timeout/invalid-slot/non-live/
stale-generation counts, `timeout_any`, sticky first-error.

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
- **Generation-wrap bound:** stale detection holds provided fewer than `2^GEN_W`
  reallocations of a given slot occur while a stale response for it is still in
  flight. Size `GEN_W` accordingly.
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
