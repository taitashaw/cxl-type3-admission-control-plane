# M1 Interface Contract — HDM config / decode / translate

This is the authoritative spec that the RTL (`rtl/csr/hdm_config.sv`,
`rtl/core/hdm_decoder.sv`, `rtl/core/dpa_translator.sv`) and the **independent**
Python reference model (`tb/models/hdm_model.py`) both implement. Differential
testing checks RTL == model across a 1/2/4/8-window, reduced/production-width
sweep (`scripts/run_hdm_regression.sh`).

## Configuration (registered, freeze→drain→atomic-commit FSM)

Windows are configured through **shadow** registers. `cfg_update_req` starts a
reconfiguration that runs a 3-state FSM:

```
ACTIVE  req_accept_enable=1. On cfg_update_req:
          shadow invalid -> reject now (no freeze), stay ACTIVE
          shadow valid    -> FREEZE
FREEZE  traffic_freeze=1, req_accept_enable=0 (no NEW request accepted);
          wait until outstanding_cnt==0 (in-flight old-epoch traffic drains)
COMMIT  copy shadow->active atomically, cfg_epoch++, cfg_ok; -> ACTIVE
```

The validated shadow is snapshotted into an immutable **pending** copy at accept;
COMMIT writes active from *pending*, so a shadow rewrite between accept and commit
cannot corrupt the update. Because active config changes **only** in COMMIT —
entered only after admission is frozen and `outstanding_cnt` reaches 0 — the
**active configuration remains stable until admission is frozen and all reported
outstanding transactions have drained** (formally verified, `formal/config.sby`).
The request path must gate its acceptance on `req_accept_enable`.

> Per-request epoch *capture* ("each accepted request carries exactly one config
> epoch") is **deferred**: it cannot be proved until the outstanding tracker
> stores an epoch alongside each accepted tag **and** is wired to `cfg_epoch`.
> Not claimed yet.

### Update disposition — exact current behavior (no universal claim)

`cfg_update_req` is a **1-cycle pulse**, not a valid/ready transaction. Precisely:

| state when a request arrives | disposition |
|---|---|
| ACTIVE, shadow valid | accepted → snapshot → FREEZE (later `cfg_ok` + `cfg_update_done`) |
| ACTIVE, shadow invalid | `cfg_reject` + `cfg_update_done`, reason = validation code |
| FREEZE (update in flight) | `cfg_reject` + `cfg_update_done`, reason = `CFG_BUSY`; sticky `cfg_busy_seen` |
| COMMIT (single cycle) | **sticky `cfg_busy_seen` only** — the commit owns the `done`/`cfg_ok` pulse this cycle; the request is dropped and must be retried |

So a request arriving in the COMMIT cycle does **not** receive a pulse
disposition. **Therefore no claim is made that every update request receives an
observable disposition.** `cfg_busy` (level) always indicates an in-flight
update, so software can poll, but the correct fix is a real handshake:
`cfg_update_valid`/`cfg_update_ready` + `cfg_response_valid`/`cfg_response_code
∈ {OK, INVALID, BUSY}`, where acceptance is `valid && ready` and a held `valid`
is never lost. **That handshake is planned and not yet implemented.**

A reconfiguration is **rejected** immediately (active config unchanged, no epoch
bump, no freeze) if, for any enabled window, in this priority order:

| reason code | condition |
|---|---|
| 1 `ZERO_SIZE`  | `size == 0` |
| 2 `BASE_ALIGN` | `base % 64 != 0` |
| 3 `SIZE_ALIGN` | `size % 64 != 0` |
| 4 `DPA_ALIGN`  | `dpa_base % 64 != 0` |
| 5 `HPA_OVF`    | `base + size > 2^HPA_W` |
| 6 `DPA_OVF`    | `dpa_base + size > 2^DPA_W` |
| 7 `CAP_EXCEED` | `dpa_base + size > dev_capacity` |
| 8 `OVERLAP`    | two enabled windows overlap in HPA |

On success: active ← shadow atomically, `cfg_epoch` increments, `cfg_ok` +
`cfg_update_done` pulse. All address arithmetic uses guard bits (no wrapped
native-width compare).

## Decode (combinational, fail-closed)

Against the **active** config, for an incoming HPA:

- **0 matches** → `miss` (no accept)
- **exactly 1 match** → `single_match` → translation authorized
- **≥2 matches** → `overlap_reject` (fail closed; never silently priority-selects)

`win_id` is a **diagnostic** (lowest matching index) and never authorizes a
transaction on its own. `unaligned = (hpa % 64 != 0)`.

## Translate (widened arithmetic, full-64B-line taxonomy)

Bounds cover the COMPLETE 64-byte line, not just the start address. On
`single_match` (with `line_oob = hpa+63 ≥ window_limit` from the decoder):
```
offset          = hpa - matched_base           (underflow flagged if hpa < base; must not occur)
dpa             = matched_dpa_base + offset
xlate_overflow  = dpa+63 >= 2^DPA_W             (line-end wraps DPA space)
dpa_oob         = dpa+63 >= dev_capacity        (line-end past installed device)
accept          = single_match & ~unaligned & ~line_oob & ~xlate_overflow & ~dpa_oob
```
With no single match: `dpa = 0`, no error flags, `accept = 0`.

## Formal properties (PROVED — `make formal`)

SymbiYosys (local OSS CAD Suite) proves, with bounded model checking AND
unbounded induction:

Decoder/translator (`formal/decode.sby`): accept ⇒ exactly one match; overlap ⇒
¬accept; accept ⇒ aligned; accept ⇒ ¬line_oob (whole line in window); accept ⇒
¬underflow∧¬overflow∧¬oob; accept ⇒ dpa = dpa_base+(hpa−base); one-hot
classification.

Config FSM (`formal/config.sby`): epoch increments exactly once per commit;
active config changes only on commit (atomic); commit only from COMMIT; FREEZE→
COMMIT only when `outstanding_cnt==0`; `traffic_freeze ⇒ ¬req_accept_enable`.

These are genuine bounded+induction safety proofs; see `docs/limitations.md` for
the free-Yosys subset caveat (no liveness/Tabby-grade claims).
