// credit_manager.sv
// Parameterized multi-pool credit manager. Credit accounting is LEDGER logic:
// it never clamps, never partially updates, and never silently tolerates an
// illegal return — any of those would destroy auditability.
//
// AUTHORITATIVE STATE (single source of truth, no divergence possible):
//     used[p], configured_max[p]
// DERIVED:
//     available[p] = configured_max[p] - used[p]
// INVARIANT:
//     0 <= used[p] <= configured_max[p]
//
// ALL-OR-NOTHING: a consume is legal only if EVERY pool has enough credit; a
// return is legal only if EVERY pool has at least the returned amount. A partial
// multi-pool update never occurs.
//
// NO COMBINATIONAL RETURN->CONSUME BYPASS: consume legality is derived from the
// REGISTERED pre-cycle state, so credits returned this cycle cannot enable a
// consume this cycle. This deliberately avoids the loop
//   response -> credit return -> request ready -> request generation -> response
// A registered bypass stage may be added later if throughput analysis demands it.
//
// SATURATION POLICY: diagnostic counters saturate; FUNCTIONAL state (used /
// configured_max) never saturates, wraps or clamps. Illegal operations are
// REJECTED with the functional state preserved and a sticky first-error snapshot.
`ifndef CREDIT_MANAGER_SV
`define CREDIT_MANAGER_SV

module credit_manager #(
  parameter int unsigned N_POOLS   = 2,
  parameter int unsigned COUNT_W   = 8,     // width of used/max
  parameter int unsigned AMT_W     = 4,     // width of consume/return amounts
  parameter int unsigned CNT_W     = 32,    // diagnostic counter width
  parameter int unsigned RESET_MAX = 0,     // per-pool maximum at reset (documented default)
  parameter int unsigned PIDX_W    = (N_POOLS <= 1) ? 1 : $clog2(N_POOLS)
) (
  input  logic                            clk,
  input  logic                            rst_n,

  // ---- consume (reservation) ----
  input  logic                            consume_valid,
  input  logic [N_POOLS-1:0][AMT_W-1:0]   consume_amount,
  output logic                            consume_ready,   // legality from REGISTERED state
  output logic                            consume_fire,

  // ---- return ----
  input  logic                            return_valid,
  input  logic [N_POOLS-1:0][AMT_W-1:0]   return_amount,
  output logic                            return_accepted,

  // ---- atomic configuration (from the M2.1 controller) ----
  input  logic [N_POOLS-1:0][COUNT_W-1:0] committed_max,
  input  logic                            config_commit,
  input  logic                            frozen_and_empty, // frozen && tracker occ==0 && !alloc_fire
  input  logic                            diagnostic_clear,

  // ---- status ----
  output logic [N_POOLS-1:0][COUNT_W-1:0] used,
  output logic [N_POOLS-1:0][COUNT_W-1:0] available,
  output logic [N_POOLS-1:0][COUNT_W-1:0] configured_max,
  output logic [N_POOLS-1:0]              pool_full,
  output logic [N_POOLS-1:0]              pool_empty,
  output logic [N_POOLS-1:0][COUNT_W-1:0] hwm_used,

  // ---- diagnostics ----
  output logic                            sticky_err,
  output logic [2:0]                      first_err_type,
  output logic [PIDX_W-1:0]               first_err_pool,
  output logic [AMT_W-1:0]                first_err_amount,
  output logic [CNT_W-1:0]                consume_ok_count,
  output logic [CNT_W-1:0]                consume_blocked_count,
  output logic [CNT_W-1:0]                return_ok_count,
  output logic [CNT_W-1:0]                return_illegal_count,
  output logic [CNT_W-1:0]                cfg_reject_count
);
  // error types
  localparam logic [2:0] ERR_NONE=0, ERR_RETURN_UNDERFLOW=1, ERR_CFG_REJECT=2;

  // saturating diagnostic increment (funcname= style -> Yosys-portable)
  function automatic logic [CNT_W-1:0] sat1(input logic [CNT_W-1:0] c);
    if (&c) sat1 = c;
    else    sat1 = c + {{(CNT_W-1){1'b0}},1'b1};
  endfunction

  // ---- derived availability (single authoritative state) -------------------
  genvar gp;
  generate
    for (gp = 0; gp < N_POOLS; gp++) begin : g_avail
      assign available[gp]  = configured_max[gp] - used[gp];   // invariant: used<=max
      assign pool_full[gp]  = (used[gp] == configured_max[gp]);
      assign pool_empty[gp] = (used[gp] == '0);
    end
  endgenerate

  // ---- legality (ALL-OR-NOTHING, from REGISTERED pre-cycle state) ----------
  // Comparisons use EXPLICIT width-matched locals (COUNT_W+1, one guard bit)
  // rather than nested replication-concatenations inline: the inline form was
  // evaluated differently by Verilator and Icarus (proven by differential test),
  // so the widths are made unambiguous here.
  localparam int unsigned CMP_W = COUNT_W + 1;
  logic [N_POOLS-1:0] c_ok_pool, r_ok_pool;
  generate
    for (gp = 0; gp < N_POOLS; gp++) begin : g_legal
      logic [CMP_W-1:0] camt_x, ramt_x, avail_x, used_x;
      assign camt_x  = CMP_W'(consume_amount[gp]);
      assign ramt_x  = CMP_W'(return_amount[gp]);
      assign avail_x = CMP_W'(available[gp]);
      assign used_x  = CMP_W'(used[gp]);
      assign c_ok_pool[gp] = (camt_x <= avail_x);
      assign r_ok_pool[gp] = (ramt_x <= used_x);
    end
  endgenerate
  logic consume_legal, return_legal;
  assign consume_legal   = &c_ok_pool;              // every pool must have room
  assign return_legal    = &r_ok_pool;              // every pool must hold >= amount
  assign consume_ready   = consume_legal;
  assign consume_fire    = consume_valid && consume_ready;
  assign return_accepted = return_valid && return_legal;

  logic illegal_return;
  assign illegal_return  = return_valid && !return_legal;

  // ---- configuration: atomic, only while frozen/empty and fully unused -----
  logic all_unused;
  always_comb begin
    all_unused = 1'b1;
    for (int p = 0; p < N_POOLS; p++) if (used[p] != '0) all_unused = 1'b0;
  end
  // A consume is the credit-side of an allocation, so the commit gate must
  // exclude it exactly as the tracker's gate excludes alloc_fire. Without this,
  // a consume checked against the OLD max could land on the same edge as a new
  // (smaller) max, leaving used > configured_max and making the derived
  // `available` underflow -- corrupting the ledger.
  logic cfg_gate_ok;
  assign cfg_gate_ok = frozen_and_empty && all_unused && !consume_fire;
  logic cfg_apply, cfg_refuse;
  assign cfg_apply  = config_commit &&  cfg_gate_ok;
  assign cfg_refuse = config_commit && !cfg_gate_ok;

  // first offending pool/amount for the sticky snapshot
  logic [PIDX_W-1:0] first_bad_ret_pool;
  logic [AMT_W-1:0]  first_bad_ret_amt;
  always_comb begin
    first_bad_ret_pool = '0; first_bad_ret_amt = '0;
    for (int p = N_POOLS-1; p >= 0; p--)
      if (!r_ok_pool[p]) begin
        first_bad_ret_pool = p[PIDX_W-1:0];
        first_bad_ret_amt  = return_amount[p];
      end
  end

  // Error selection is resolved COMBINATIONALLY with explicit priority, then
  // written once. Two separate `if (!sticky_err) ... <= ...` blocks would both
  // read the same pre-edge sticky_err and the LAST nonblocking write would win,
  // silently defeating the priority.
  logic              err_now;
  logic [2:0]        err_type_now;
  logic [PIDX_W-1:0] err_pool_now;
  logic [AMT_W-1:0]  err_amt_now;
  always_comb begin
    err_now = 1'b0; err_type_now = ERR_NONE; err_pool_now = '0; err_amt_now = '0;
    if (illegal_return) begin                       // priority: ledger error first
      err_now = 1'b1; err_type_now = ERR_RETURN_UNDERFLOW;
      err_pool_now = first_bad_ret_pool; err_amt_now = first_bad_ret_amt;
    end else if (cfg_refuse) begin
      err_now = 1'b1; err_type_now = ERR_CFG_REJECT;
    end
  end

  // ---- next-state ledger (widened; never clamps) ---------------------------
  logic [COUNT_W:0] next_used_w [N_POOLS];   // one guard bit
  always_comb begin
    for (int p = 0; p < N_POOLS; p++) begin
      next_used_w[p] = {1'b0, used[p]};
      if (consume_fire)    next_used_w[p] = next_used_w[p] + {{(COUNT_W+1-AMT_W){1'b0}}, consume_amount[p]};
      if (return_accepted) next_used_w[p] = next_used_w[p] - {{(COUNT_W+1-AMT_W){1'b0}}, return_amount[p]};
    end
  end

  integer p;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (p = 0; p < N_POOLS; p++) begin
        used[p]           <= '0;
        configured_max[p] <= COUNT_W'(RESET_MAX);   // documented reset default
        hwm_used[p]       <= '0;
      end
      sticky_err<=1'b0; first_err_type<=ERR_NONE; first_err_pool<='0; first_err_amount<='0;
      consume_ok_count<='0; consume_blocked_count<='0; return_ok_count<='0;
      return_illegal_count<='0; cfg_reject_count<='0;
    end else begin
      // ---- FUNCTIONAL LEDGER (always runs; diagnostics must never gate it) ---
      // both operations are all-or-nothing and applied together
      if (consume_fire || return_accepted) begin
        for (p = 0; p < N_POOLS; p++) begin
          used[p] <= next_used_w[p][COUNT_W-1:0];
          if (next_used_w[p][COUNT_W-1:0] > hwm_used[p]) hwm_used[p] <= next_used_w[p][COUNT_W-1:0];
        end
      end
      // configuration: all pool maxima change atomically, or none
      if (cfg_apply) begin
        for (p = 0; p < N_POOLS; p++) configured_max[p] <= committed_max[p];
      end

      // ---- DIAGNOSTICS (separate from the ledger) ---------------------------
      if (diagnostic_clear) begin
        sticky_err<=1'b0; first_err_type<=ERR_NONE; first_err_pool<='0; first_err_amount<='0;
        consume_ok_count<='0; consume_blocked_count<='0; return_ok_count<='0;
        return_illegal_count<='0; cfg_reject_count<='0;
        // watermark restarts from the post-update occupancy
        for (p = 0; p < N_POOLS; p++)
          hwm_used[p] <= (consume_fire || return_accepted) ? next_used_w[p][COUNT_W-1:0] : used[p];
      end else begin
        if (consume_fire)                    consume_ok_count      <= sat1(consume_ok_count);
        if (consume_valid && !consume_ready) consume_blocked_count <= sat1(consume_blocked_count);
        if (return_accepted)                 return_ok_count       <= sat1(return_ok_count);
        // illegal return: REJECTED above (ledger untouched)
        if (illegal_return) return_illegal_count <= sat1(return_illegal_count);
        if (cfg_refuse)     cfg_reject_count     <= sat1(cfg_reject_count);
        // SINGLE prioritized first-error capture (see err_now selection above)
        if (err_now && !sticky_err) begin
          sticky_err       <= 1'b1;
          first_err_type   <= err_type_now;
          first_err_pool   <= err_pool_now;
          first_err_amount <= err_amt_now;
        end
      end
    end
  end

`ifdef FORMAL
  // ---- ledger safety properties (bmc + induction) --------------------------
  logic f_init;
  logic [COUNT_W-1:0] f_pused0, f_pmax0, f_phwm0;
  logic               f_pcfire, f_pracc, f_pcfg_apply;
  logic [AMT_W-1:0]   f_pcamt0, f_pramt0;
  initial f_init = 1'b0;
  always_ff @(posedge clk) begin
    f_init<=1'b1; f_pused0<=used[0]; f_pmax0<=configured_max[0]; f_phwm0<=hwm_used[0];
    f_pcfire<=consume_fire; f_pracc<=return_accepted; f_pcfg_apply<=cfg_apply;
    f_pcamt0<=consume_amount[0]; f_pramt0<=return_amount[0];
  end

  always @(posedge clk) begin
    if (rst_n && f_init) begin
      for (int q = 0; q < N_POOLS; q++) begin
        assert (used[q] <= configured_max[q]);                       // core invariant
        assert (available[q] == (configured_max[q] - used[q]));      // derived, not stored
        assert (hwm_used[q] >= used[q]);                             // watermark
      end
      // a granted consume implies EVERY pool had room (no partial consume)
      if (consume_fire) for (int q = 0; q < N_POOLS; q++)
        assert ({{(COUNT_W){1'b0}}, consume_amount[q]} <= {{AMT_W{1'b0}}, available[q]});
      // an accepted return implies EVERY pool held at least the amount
      if (return_accepted) for (int q = 0; q < N_POOLS; q++)
        assert ({{(COUNT_W){1'b0}}, return_amount[q]} <= {{AMT_W{1'b0}}, used[q]});
      // The ledger delta is EXACTLY accepted-consume minus accepted-return
      // (pool-0 witness). This subsumes "an illegal/blocked operation changes
      // nothing": if it was not accepted, its term is zero, so used is unchanged.
      // It also proves the ledger never clamps or saturates.
      assert (used[0] == (f_pused0
                          + (f_pcfire ? {{(COUNT_W-AMT_W){1'b0}}, f_pcamt0} : '0)
                          - (f_pracc  ? {{(COUNT_W-AMT_W){1'b0}}, f_pramt0} : '0)));
      // configured_max changes ONLY on a legal atomic commit
      if (!f_pcfg_apply) assert (configured_max[0] == f_pmax0);
    end
  end
`endif
endmodule
`endif
