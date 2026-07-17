// credit_manager.sv
// Parameterized multi-pool credit manager. Credit accounting is LEDGER logic:
// it never clamps, never partially updates, and never silently tolerates an
// illegal return or a non-representable configuration.
//
// PORTS ARE FLAT packed vectors ([N_POOLS*W-1:0]) sliced internally with
// `[p*W +: W]`. No packed-multidimensional element writes exist at the interface,
// so the testbench drives one whole-vector assignment per cycle and DUT indexing
// and TB mapping use the identical `p*W +: W` convention (verified by a
// walking-one port-mapping test).
//
// AUTHORITATIVE STATE (single source of truth): used[p], configured_max[p].
// DERIVED: available[p] = configured_max[p] - used[p]. INVARIANT: 0<=used<=max.
//
// ALL-OR-NOTHING across pools; NO combinational return->consume bypass (consume
// legality uses REGISTERED pre-cycle state). Diagnostic counters saturate;
// FUNCTIONAL state never saturates/clamps.
//
// CONFIGURATION is an ATOMIC EVENT, not a droppable pulse: cfg_commit_fire
// requires frozen_and_empty AND all pools unused AND every requested max
// representable; on that edge consume and return are BLOCKED. A refused commit
// is observable (cfg_reject pulse + cfg_reason + saturating counter).
`ifndef CREDIT_MANAGER_SV
`define CREDIT_MANAGER_SV

module credit_manager #(
  parameter int unsigned N_POOLS   = 2,
  parameter int unsigned COUNT_W   = 8,     // width of used/max
  parameter int unsigned AMT_W     = 4,     // width of consume/return amounts
  parameter int unsigned CNT_W     = 32,    // diagnostic counter width
  parameter int unsigned RESET_MAX = 0,     // per-pool maximum at reset
  parameter int unsigned PIDX_W    = (N_POOLS <= 1) ? 1 : $clog2(N_POOLS),
  parameter int unsigned MREQ_W    = COUNT_W + 1  // requested max: one extra bit so a
                                                  // non-representable value can be expressed & rejected
) (
  input  logic                          clk,
  input  logic                          rst_n,

  // ---- consume (reservation) ----  amounts flat: pool p = [p*AMT_W +: AMT_W]
  input  logic                          consume_valid,
  input  logic [N_POOLS*AMT_W-1:0]      consume_amount,
  output logic                          consume_ready,   // legality from REGISTERED state
  output logic                          consume_fire,

  // ---- return ----
  input  logic                          return_valid,
  input  logic [N_POOLS*AMT_W-1:0]      return_amount,
  output logic                          return_accepted,

  // ---- atomic configuration ----  requested max flat: [p*MREQ_W +: MREQ_W]
  input  logic [N_POOLS*MREQ_W-1:0]     committed_max,
  input  logic                          config_commit,
  input  logic                          frozen_and_empty,
  input  logic                          diagnostic_clear,
  output logic                          cfg_commit_fire, // config applied this edge
  output logic                          cfg_reject,      // config refused this edge (observable)
  output logic [2:0]                    cfg_reason,

  // ---- status ----  flat: [p*COUNT_W +: COUNT_W]
  output logic [N_POOLS*COUNT_W-1:0]    used,
  output logic [N_POOLS*COUNT_W-1:0]    available,
  output logic [N_POOLS*COUNT_W-1:0]    configured_max,
  output logic [N_POOLS-1:0]            pool_full,
  output logic [N_POOLS-1:0]            pool_empty,
  output logic [N_POOLS*COUNT_W-1:0]    hwm_used,

  // ---- diagnostics ----
  output logic                          sticky_err,
  output logic [2:0]                    first_err_type,
  output logic [PIDX_W-1:0]             first_err_pool,
  output logic [AMT_W-1:0]              first_err_amount,
  output logic [CNT_W-1:0]              consume_ok_count,
  output logic [CNT_W-1:0]              consume_blocked_count,
  output logic [CNT_W-1:0]              return_ok_count,
  output logic [CNT_W-1:0]              return_illegal_count,
  output logic [CNT_W-1:0]              cfg_reject_count
);
  // error / cfg-reason types
  localparam logic [2:0] ERR_NONE=0, ERR_RETURN_UNDERFLOW=1, ERR_CFG_BUSY=2, ERR_CFG_UNREP=3;

  function automatic logic [CNT_W-1:0] sat1(input logic [CNT_W-1:0] c);
    if (&c) sat1 = c;
    else    sat1 = c + {{(CNT_W-1){1'b0}},1'b1};
  endfunction

  // registered authoritative state as unpacked arrays (portable element writes)
  logic [COUNT_W-1:0] used_r [N_POOLS];
  logic [COUNT_W-1:0] cmax_r [N_POOLS];
  logic [COUNT_W-1:0] hwm_r  [N_POOLS];

  // ---- derived views + flat output packing ---------------------------------
  genvar gp;
  generate
    for (gp = 0; gp < N_POOLS; gp++) begin : g_pack
      assign used[gp*COUNT_W +: COUNT_W]           = used_r[gp];
      assign configured_max[gp*COUNT_W +: COUNT_W] = cmax_r[gp];
      assign available[gp*COUNT_W +: COUNT_W]      = cmax_r[gp] - used_r[gp]; // used<=max invariant
      assign hwm_used[gp*COUNT_W +: COUNT_W]       = hwm_r[gp];
      assign pool_full[gp]  = (used_r[gp] == cmax_r[gp]);
      assign pool_empty[gp] = (used_r[gp] == '0);
    end
  endgenerate

  // ---- legality (ALL-OR-NOTHING, from REGISTERED pre-cycle state) ----------
  localparam int unsigned CMP_W = COUNT_W + 1;
  logic [N_POOLS-1:0] c_ok_pool, r_ok_pool;
  logic [N_POOLS-1:0] cmax_unrep;
  generate
    for (gp = 0; gp < N_POOLS; gp++) begin : g_legal
      logic [AMT_W-1:0]  camt, ramt;
      assign camt = consume_amount[gp*AMT_W +: AMT_W];
      assign ramt = return_amount [gp*AMT_W +: AMT_W];
      assign c_ok_pool[gp] = (CMP_W'(camt) <= CMP_W'(cmax_r[gp] - used_r[gp]));
      assign r_ok_pool[gp] = (CMP_W'(ramt) <= CMP_W'(used_r[gp]));
      // representable iff no bit at/above COUNT_W is set (value <= 2^COUNT_W-1)
      assign cmax_unrep[gp] = |committed_max[gp*MREQ_W + COUNT_W +: (MREQ_W-COUNT_W)];
    end
  endgenerate
  logic consume_legal, return_legal;
  assign consume_legal = &c_ok_pool;
  assign return_legal  = &r_ok_pool;

  // ---- configuration as an ATOMIC EVENT ------------------------------------
  logic all_unused, cfg_representable;
  always_comb begin
    all_unused = 1'b1;
    for (int p = 0; p < N_POOLS; p++) if (used_r[p] != '0) all_unused = 1'b0;
  end
  assign cfg_representable = ~(|cmax_unrep);
  // Event pulses are gated on rst_n: the reset contract requires NO fire/accept/
  // commit/reject pulse during reset (the registered ledger is held in reset).
  assign cfg_commit_fire = rst_n && config_commit && frozen_and_empty && all_unused && cfg_representable;
  assign cfg_reject      = rst_n && config_commit && !cfg_commit_fire;
  // reason for a refusal: unrepresentable dominates (a real config error) over
  // a busy/unfrozen/occupied refusal.
  assign cfg_reason = cfg_reject ? (!cfg_representable ? ERR_CFG_UNREP : ERR_CFG_BUSY) : ERR_NONE;

  // ---- consume/return fire (config-commit edge BLOCKS both) ----------------
  assign consume_ready   = consume_legal;                         // pure legality (not gated)
  assign consume_fire    = rst_n && consume_valid && consume_legal && !cfg_commit_fire;
  assign return_accepted = rst_n && return_valid  && return_legal  && !cfg_commit_fire;
  logic illegal_return;
  assign illegal_return  = rst_n && return_valid && !return_legal && !cfg_commit_fire;

  // first offending return pool/amount for the sticky snapshot (lowest index)
  logic [PIDX_W-1:0] first_bad_ret_pool;
  logic [AMT_W-1:0]  first_bad_ret_amt;
  logic [PIDX_W-1:0] first_unrep_pool;
  always_comb begin
    first_bad_ret_pool = '0; first_bad_ret_amt = '0; first_unrep_pool = '0;
    for (int p = N_POOLS-1; p >= 0; p--) begin
      if (!r_ok_pool[p]) begin first_bad_ret_pool = p[PIDX_W-1:0]; first_bad_ret_amt = return_amount[p*AMT_W +: AMT_W]; end
      if (cmax_unrep[p]) first_unrep_pool = p[PIDX_W-1:0];
    end
  end

  // combinational prioritized first-error selection (single registered write)
  logic              err_now;
  logic [2:0]        err_type_now;
  logic [PIDX_W-1:0] err_pool_now;
  logic [AMT_W-1:0]  err_amt_now;
  always_comb begin
    err_now = 1'b0; err_type_now = ERR_NONE; err_pool_now = '0; err_amt_now = '0;
    if (illegal_return) begin
      err_now = 1'b1; err_type_now = ERR_RETURN_UNDERFLOW;
      err_pool_now = first_bad_ret_pool; err_amt_now = first_bad_ret_amt;
    end else if (cfg_reject) begin
      err_now = 1'b1; err_type_now = cfg_reason;
      err_pool_now = (!cfg_representable) ? first_unrep_pool : '0;
    end
  end

  // ---- next-state ledger (widened; never clamps) ---------------------------
  logic [COUNT_W:0] next_used_w [N_POOLS];
  always_comb begin
    for (int p = 0; p < N_POOLS; p++) begin
      next_used_w[p] = {1'b0, used_r[p]};
      if (consume_fire)    next_used_w[p] = next_used_w[p] + {{(COUNT_W+1-AMT_W){1'b0}}, consume_amount[p*AMT_W +: AMT_W]};
      if (return_accepted) next_used_w[p] = next_used_w[p] - {{(COUNT_W+1-AMT_W){1'b0}}, return_amount[p*AMT_W +: AMT_W]};
    end
  end

  integer p;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (p = 0; p < N_POOLS; p++) begin
        used_r[p] <= '0; cmax_r[p] <= COUNT_W'(RESET_MAX); hwm_r[p] <= '0;
      end
      sticky_err<=1'b0; first_err_type<=ERR_NONE; first_err_pool<='0; first_err_amount<='0;
      consume_ok_count<='0; consume_blocked_count<='0; return_ok_count<='0;
      return_illegal_count<='0; cfg_reject_count<='0;
    end else begin
      // functional ledger (all-or-nothing; diagnostics never gate it)
      if (consume_fire || return_accepted) begin
        for (p = 0; p < N_POOLS; p++) begin
          used_r[p] <= next_used_w[p][COUNT_W-1:0];
          if (next_used_w[p][COUNT_W-1:0] > hwm_r[p]) hwm_r[p] <= next_used_w[p][COUNT_W-1:0];
        end
      end
      // atomic configuration: all maxima change together, or none
      if (cfg_commit_fire) begin
        for (p = 0; p < N_POOLS; p++) cmax_r[p] <= committed_max[p*MREQ_W +: COUNT_W]; // representable -> low bits
      end

      // diagnostics (separate from the ledger)
      if (diagnostic_clear) begin
        sticky_err<=1'b0; first_err_type<=ERR_NONE; first_err_pool<='0; first_err_amount<='0;
        consume_ok_count<='0; consume_blocked_count<='0; return_ok_count<='0;
        return_illegal_count<='0; cfg_reject_count<='0;
        for (p = 0; p < N_POOLS; p++)
          hwm_r[p] <= (consume_fire || return_accepted) ? next_used_w[p][COUNT_W-1:0] : used_r[p];
      end else begin
        if (consume_fire)                    consume_ok_count      <= sat1(consume_ok_count);
        if (consume_valid && !consume_ready && !cfg_commit_fire) consume_blocked_count <= sat1(consume_blocked_count);
        if (return_accepted)                 return_ok_count       <= sat1(return_ok_count);
        if (illegal_return)                  return_illegal_count  <= sat1(return_illegal_count);
        if (cfg_reject)                      cfg_reject_count      <= sat1(cfg_reject_count);
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
  logic [COUNT_W-1:0] f_pused0, f_pmax0;
  logic               f_pcfire, f_pracc, f_pcfg;
  logic [AMT_W-1:0]   f_pcamt0, f_pramt0;
  initial f_init = 1'b0;
  always_ff @(posedge clk) begin
    f_init<=1'b1; f_pused0<=used_r[0]; f_pmax0<=cmax_r[0];
    f_pcfire<=consume_fire; f_pracc<=return_accepted; f_pcfg<=cfg_commit_fire;
    f_pcamt0<=consume_amount[0 +: AMT_W]; f_pramt0<=return_amount[0 +: AMT_W];
  end
  always @(posedge clk) begin
    if (rst_n && f_init) begin
      for (int q = 0; q < N_POOLS; q++) begin
        assert (used_r[q] <= cmax_r[q]);                                  // core invariant
        assert (hwm_r[q] >= used_r[q]);                                   // watermark
      end
      // config commit blocks consume and return on the same edge
      if (cfg_commit_fire) assert (!consume_fire && !return_accepted);
      // configuration event exclusivity: apply and reject are mutually exclusive,
      // and either implies config_commit was asserted
      assert (!(cfg_commit_fire && cfg_reject));
      assert (!(cfg_commit_fire || cfg_reject) || config_commit);
      // NO return->consume bypass: consume_ready is a pure function of REGISTERED
      // state (used_r/cmax_r) and consume_amount -- independent of return_*.
      assert (consume_ready == (&c_ok_pool));
      // DETERMINISTIC first-error priority: an illegal return outranks a config
      // refusal for the sticky snapshot.
      if (illegal_return)                    assert (err_type_now == ERR_RETURN_UNDERFLOW);
      else if (cfg_reject)                   assert (err_type_now == cfg_reason);
      else                                   assert (!err_now);
      // a granted consume implies EVERY pool had room (no partial consume)
      if (consume_fire) for (int q = 0; q < N_POOLS; q++)
        assert ({{(COUNT_W+1-AMT_W){1'b0}}, consume_amount[q*AMT_W +: AMT_W]}
                <= {1'b0, (cmax_r[q] - used_r[q])});
      // an accepted return implies EVERY pool held at least the amount
      if (return_accepted) for (int q = 0; q < N_POOLS; q++)
        assert ({{(COUNT_W+1-AMT_W){1'b0}}, return_amount[q*AMT_W +: AMT_W]}
                <= {1'b0, used_r[q]});
      // pool-0 ledger delta is EXACTLY accepted-consume minus accepted-return
      // (subsumes: illegal/blocked op changes nothing; never clamps/saturates)
      assert (used_r[0] == (f_pused0
                            + (f_pcfire ? {{(COUNT_W-AMT_W){1'b0}}, f_pcamt0} : '0)
                            - (f_pracc  ? {{(COUNT_W-AMT_W){1'b0}}, f_pramt0} : '0)));
      // configured_max changes ONLY on a legal atomic commit
      if (!f_pcfg) assert (cmax_r[0] == f_pmax0);
    end
  end
`endif
endmodule
`endif
