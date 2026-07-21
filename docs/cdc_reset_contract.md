# M7 Design Contract — CDC / Reset Infrastructure

`sync_bits`, `reset_sync`, `async_fifo`. Clock-domain-crossing and reset
primitives that bridge the link/front-end clock domain and the memory/back-end
clock domain. **Safety only**; the metastability (MTBF) resolution of each
synchronizer is an explicit *assumption*, never a proof.

## 1. Scope and result-class discipline

| Property | Result class | How |
|----------|--------------|-----|
| No FIFO overflow / underflow | FORMAL (unbounded k-induction) | `async_fifo.sby` prove |
| Gray-code invariant (single-bit change, gray==bin^(bin>>1)) | FORMAL (induction) | `async_fifo.sby` prove |
| Synchronized-pointer lag bound (synced ptr never leads the true ptr) | FORMAL (induction) | `async_fifo.sby` prove |
| End-to-end data integrity (dequeue[k] == enqueue[k]) | FORMAL (induction) | `async_fifo.sby` prove |
| `sync_bits` / `reset_sync` structural depth (STAGES>=2) | FORMAL (induction) | `cdc.sby` prove |
| Metastable-bit resolution within one destination cycle | **ASSUMPTION** (MTBF) | modeled by the free-running two-clock harness; NOT proven |
| Liveness / eventual drain / eventual flag update | **NOT CLAIMED** | a stalled domain clock blocks progress |

No BMC fallback is used for any safety property above. Non-vacuity is shown by
covers and by sim+formal mutation.

## 2. `sync_bits` — level-signal synchronizer

```
sync_bits #(parameter int unsigned WIDTH=1, parameter int unsigned STAGES=2)
( input  logic              clk_dst,
  input  logic              rst_dst_n,
  input  logic [WIDTH-1:0]  d_src,      // free-running source-domain vector
  output logic [WIDTH-1:0]  q_dst );    // = stage[STAGES-1]
```
- `STAGES` flip-flops in `clk_dst`; `q_dst` taps the LAST stage only.
- Intended for signals that are gray-coded or otherwise safe to sample bit-by-bit
  (each bit may go metastable, but the sampled vector resolves to a legal
  old/new value). Do **not** use for multi-bit binary buses.
- Reset: `rst_dst_n` async-asserts, all stages to 0.

## 3. `reset_sync` — async-assert / sync-deassert reset bridge

```
reset_sync #(parameter int unsigned STAGES=2)
( input  logic clk_dst,
  input  logic arst_n_in,       // async reset (any domain / POR)
  output logic rst_dst_n_out );  // async assert, synchronized deassert in clk_dst
```
- Deassertion is synchronized through `STAGES` flops so the destination domain
  leaves reset cleanly; assertion is immediate.

## 4. `async_fifo` — dual-clock FIFO (power-of-two depth)

```
async_fifo #(parameter int unsigned WIDTH=8,
             parameter int unsigned ADDR_W=3)      // DEPTH = 2**ADDR_W (gray wrap needs pow2)
( // write domain
  input  logic              wr_clk, wr_rst_n,
  input  logic              wr_en,
  input  logic [WIDTH-1:0]  wr_data,
  output logic              full,
  // read domain
  input  logic              rd_clk, rd_rst_n,
  input  logic              rd_en,
  output logic [WIDTH-1:0]  rd_data,
  output logic              empty,
  // flat observation ports (induction without cross-module index)
  output logic [ADDR_W:0]   dbg_wbin, dbg_wgray, dbg_rbin, dbg_rgray,
  output logic [ADDR_W:0]   dbg_wgray_s, dbg_rgray_s,        // synchronized pointers
  output logic [(1<<ADDR_W)*WIDTH-1:0] dbg_mem );
```

### Pointers
- `wbin`, `rbin` are `ADDR_W+1` bits (one extra MSB) so full/empty are
  distinguishable after a full wrap. Gray codes: `gray = bin ^ (bin>>1)`.
- Memory index is the low `ADDR_W` bits.

### Flags (standard gray-pointer formulation)
- `full  = (wgray == {~rgray_s[ADDR_W:ADDR_W-1], rgray_s[ADDR_W-2:0]})`
  (top two gray bits inverted, rest equal — write has lapped read by DEPTH).
- `empty = (rgray == wgray_s)`.

### Synchronizers
- `wgray` -> `sync_bits(STAGES=2)` in `rd_clk` -> `wgray_s`.
- `rgray` -> `sync_bits(STAGES=2)` in `wr_clk` -> `rgray_s`.

### Accept conditions
- Write commits iff `wr_en && !full`; read commits iff `rd_en && !empty`.

## 5. Formal harness (two independent clocks)

`formal/async_fifo.sby` and `formal/cdc.sby` run with **`multiclock on`**. The
wrapper drives `wr_clk` and `rd_clk` as *independent* clocks under a global
formal clock; the solver freely chooses each domain's edges, so all relative
clock frequencies/phases are covered. Properties are evaluated on the global
clock. This free-running two-clock model is exactly what encodes the MTBF
assumption: because every crossing pointer is gray-coded (one-bit change), any
metastable sample resolves to the legal pre- or post-value the model already
admits.

### Invariants proved by induction
1. **Bounds** — occupancy (true `wbin - rbin`) in `[0, DEPTH]`; never write when
   `full`, never read when `empty`.
2. **Gray consistency** — `wgray == wbin^(wbin>>1)`, `rgray == rbin^(rbin>>1)`;
   successive pointer values differ by exactly one gray bit.
3. **Lag bound** — the synchronized read pointer is behind-or-equal to the true
   read pointer (never ahead); symmetric for the synchronized write pointer.
   This is the inductive core that makes `full`/`empty` conservative (may be
   stale but never wrong in the unsafe direction).
4. **Data integrity** — for a symbolic slot / write index `f_idx` (`anyconst`),
   the value delivered when the read pointer reaches `f_idx` equals the value
   written there, and `mem[f_idx]` is not overwritten while that entry is in
   flight (written, not yet read).

### Covers (non-vacuity)
fill-to-full, drain-to-empty, simultaneous write+read edge, pointer wrap-around,
reset asserted in each domain independently.

## 6. Mutation targets (must all be killed)

Formal (`scripts/run_formal_mutation.sh`) and sim (`scripts/run_mutation_tests.sh`):
- **binary compare** — full/empty compare `wbin/rbin` instead of gray -> wrap
  hazard -> bounds/data-integrity fail.
- **dropped MSB inversion** — `full` uses `rgray_s` directly (no top-two-bit
  invert) -> false-not-full at DEPTH -> overflow -> bounds fail.
- **single-stage synchronizer** — `STAGES` reduced to 1 -> structural
  `STAGES>=2` assert fails (CDC depth).
- **skipped gray<->bin conversion** — memory addressed by gray -> data integrity
  fails.
- `reset_sync`: synchronous assert instead of async -> reset-recovery assert fails.

## 7. Verification lanes (same standard as M1-M6)
Independent Python model (two domains advanced by nondeterministic ticks) +
two-toolchain differential (system Icarus 12.0 + Verilator 5.020 AND OSS CAD
Suite Icarus 14.0 + Verilator 5.051); SymbiYosys bmc + prove(induction) + cover;
five-instance parameter matrix; sim + formal mutation non-vacuity; AMD XSim
third engine; exact-commit clean-clone under `env -i`.

## 8. Explicit non-claims
No metastability *proof* (MTBF assumed). No liveness/fairness. No claim about
real asynchronous timing, jitter, or MTBF numbers. Not a substitute for STA
CDC sign-off (Quartus/Conformal lanes remain BLOCKED on this host).
