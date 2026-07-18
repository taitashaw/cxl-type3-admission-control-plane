# M4 Phase 2c — Atomic Global Configuration Commit (`config_ctrl` / `control_plane_top`)

`rtl/csr/config_ctrl.sv` + `rtl/core/control_plane_top.sv` add ONE atomic global
configuration commit over the whole admission control plane. Verified against an
independent model (`tb/models/config_model.py`) that wraps the admission model with
the config FSM.

## Configuration payload (bundled, committed together)
HDM window base/size, capacity, timeout enable + threshold, per-pool credit maxima
in **pre-truncation** form (`MREQ_W = COUNT_W+1`), and the config epoch. The
decoupled M2.1 handshake is preserved: `cfg_req_valid/ready` + `cfg_rsp_valid/ready/
code/reason`. Acceptance is only on `cfg_req_valid && cfg_req_ready`; the **complete**
payload is snapshot **exactly once** into an immutable `pending` register, so later
requester/shadow changes cannot affect the in-flight transaction.

## Validation → freeze → drain → shared commit → response
Every field is validated **before** freezing. An **invalid** request produces one
registered `INVALID` response with a deterministic reason (timeout > cmax > hdm),
and **never** freezes traffic, changes active config, or partially commits. A
**valid** request:
1. disables new admission (`req_accept_enable` low outside `IDLE`);
2. drains until **full quiescence** — `occupancy==0`, `quarantined_count==0`,
   `credit_used[p]==0` ∀p, issue buffer empty, and no `req_accept`,
   `retire_commit_fire` or `reclaim_commit_fire` in flight;
3. emits **one** `global_cfg_commit_fire`;
4. on that same edge every active field updates from `pending` (the credit manager
   latches its maxima from the pending snapshot on the same edge);
5. produces the `OK` response only after the shared commit.

## Proved by induction (`formal/control_plane.sby` + `config_ctrl` asserts)
- **Atomic bundle:** every active field changes **iff** `global_cfg_commit_fire`,
  all from the same `pending` snapshot — **no partial update** is reachable.
- **Shared commit:** `global_cfg_commit_fire == credit_cfg_commit_fire`; a local
  credit-manager rejection on the shared commit is **unreachable**.
- **Quiescence (B4):** the commit implies `occupancy==0`, `quarantined_count==0`,
  every `credit_used==0`, and the issue buffer empty — **no live entry crosses a
  commit** (`credit_used==0` follows from `occupancy==0` via conservation, and is
  asserted directly for completeness).
- **Freeze:** `req_accept_enable` is high **only** in `IDLE`; admission produces no
  side effect while (re)configuring (composes with the admission A2 theorem).
- **Response:** the `OK` response appears only after a commit; `INVALID` never
  coincides with a commit. Commit is from the immutable `pending`, never the shadow.
- **Preserved from below:** the admission conservation (mathematical equality),
  A2, epoch capture, and all tracker/credit invariants still hold in the integrated
  system, including **across** a configuration commit.
- **Strengthening invariant:** `DRAIN`/`RSP_OK` imply the pending snapshot is valid,
  which makes the representability-gated credit commit coincide with the shared edge.

## Verification lanes
- **Differential sweep** (`scripts/run_control_plane_sweep.sh`) — 4 configs × 4000
  cyc, two-toolchain (system Icarus 12.0 + Verilator 5.020 **and** OSS CAD Suite
  Icarus 14.0 + Verilator 5.051), 0 errors; the model self-checks conservation
  every cycle (incl. across commits). 84–117 commits per config.
- **Formal** — `control_plane.sby` bmc + prove(induction) + cover PASS, 0 unreached.
  `control_plane_matrix.sby` = **five selected instances** (DEPTH=1; non-pow2
  DEPTH=3; three pools; `COUNT_W=AMT_W+1`; wider-`AMT_W` dual-return), each prove +
  cover: **10/10 tasks** (not a Cartesian product), reported separately.
- **Sim mutation** — killed: commit-from-shadow, partial-config-update (epoch),
  admission-fires-while-frozen.
- **Formal mutation** — killed: commit-from-shadow, partial-update,
  commit-needs-occupancy-zero, commit-while-issue-occupied, admission-frozen.
- **XSim** — reduced third-engine cross-check PASS.

## Honest limitations (no general liveness)
Drain progress is **not** guaranteed: it can remain blocked by a non-responding
transaction, a quarantined entry never reclaimed, a stalled issue buffer, or a
requester that never completes the recovery protocol. Only **safety** is proved
(the commit is atomic and quiescent *when* it occurs). Timeout alone returns no
credit; valid retirement and successful reclaim remain the only functional return
authorities. The HDM/capacity fields are carried and committed atomically as
configuration words; HDM address **decode** itself is the separately verified M1
block and is not re-derived here.
