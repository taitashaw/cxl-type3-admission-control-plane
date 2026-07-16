# M1 Interface Contract — HDM config / decode / translate

This is the authoritative spec that the RTL (`rtl/csr/hdm_config.sv`,
`rtl/core/hdm_decoder.sv`, `rtl/core/dpa_translator.sv`) and the **independent**
Python reference model (`tb/models/hdm_model.py`) both implement. Differential
testing checks RTL == model across a 1/2/4/8-window, reduced/production-width
sweep (`scripts/run_hdm_regression.sh`).

## Configuration (registered, atomic commit)

Windows are configured through **shadow** registers, then `commit` atomically
promotes shadow→active iff the config is valid **and** the datapath is drained.

A commit is **rejected** (active config unchanged, no epoch bump) if, for any
enabled window, in this priority order:

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
| 9 `BUSY`       | `outstanding_cnt != 0` (drain required) — checked before validation |

On success: active ← shadow atomically, `cfg_epoch` increments, `cfg_committed`
pulses. All address arithmetic uses guard bits (no wrapped native-width compare).

## Decode (combinational, fail-closed)

Against the **active** config, for an incoming HPA:

- **0 matches** → `miss` (no accept)
- **exactly 1 match** → `single_match` → translation authorized
- **≥2 matches** → `overlap_reject` (fail closed; never silently priority-selects)

`win_id` is a **diagnostic** (lowest matching index) and never authorizes a
transaction on its own. `unaligned = (hpa % 64 != 0)`.

## Translate (widened arithmetic, explicit taxonomy)

On `single_match`:
```
offset          = hpa - matched_base           (underflow flagged if hpa < base; must not occur)
dpa             = matched_dpa_base + offset
xlate_overflow  = dpa >= 2^DPA_W                (DPA-space wrap)
dpa_oob         = dpa >= dev_capacity           (past installed device)
accept          = single_match & ~unaligned & ~xlate_overflow & ~dpa_oob
```
With no single match: `dpa = 0`, no error flags, `accept = 0`.

## Formal properties (written; proof BLOCKED here)

Under `` `ifdef FORMAL `` in the RTL, ready for SymbiYosys:
- classification is one-hot/total (`miss + single_match + overlap_reject == 1`)
- `single_match ⇔ popcount(match_onehot) == 1`
- `single_match ⇒ hpa ≥ matched_base` (no underflow)

Unbounded formal proof is BLOCKED on this host (sby not installed; see
`docs/limitations.md`). The same invariants are checked every vector at the
settled sample point in simulation, and the properties are mutation-tested.
