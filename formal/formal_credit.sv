// formal_credit.sv — small-parameter free-input wrapper around credit_manager.
// Safety ASSERTS live in credit_manager under `ifdef FORMAL; this wrapper drives
// free stimulus and the COVER statements that demonstrate non-vacuity.
// Reset: initial assume(!rst_n); rst_n free afterwards.
module formal_credit #(
  parameter int unsigned N_POOLS   = 2,
  parameter int unsigned COUNT_W   = 3,
  parameter int unsigned AMT_W     = 2,
  parameter int unsigned RESET_MAX = 2,
  parameter int unsigned DIAG_W    = 3,
  parameter int unsigned PIDX_W    = (N_POOLS <= 1) ? 1 : $clog2(N_POOLS),
  parameter int unsigned MREQ_W    = COUNT_W + 1
)(
  input logic clk
);
  localparam logic [2:0] ERR_RETURN_UNDERFLOW=1, ERR_CFG_UNREP=3;

  logic                rst_n;
  logic                consume_valid, return_valid, config_commit, frozen_and_empty, diagnostic_clear;
  logic [N_POOLS*AMT_W-1:0]  consume_amount, return_amount;
  logic [N_POOLS*MREQ_W-1:0] committed_max;
  logic                consume_ready, consume_fire, return_accepted, cfg_commit_fire, cfg_reject;
  logic [2:0]          cfg_reason;
  logic [N_POOLS*COUNT_W-1:0] used, available, configured_max, hwm_used;
  logic [N_POOLS-1:0]  pool_full, pool_empty;
  logic                sticky_err;
  logic [2:0]          first_err_type;
  logic [PIDX_W-1:0]   first_err_pool;
  logic [AMT_W-1:0]    first_err_amount;
  logic [DIAG_W-1:0]   consume_ok_count, consume_blocked_count, return_ok_count,
                       return_illegal_count, cfg_reject_count;

  credit_manager #(.N_POOLS(N_POOLS), .COUNT_W(COUNT_W), .AMT_W(AMT_W),
                   .RESET_MAX(RESET_MAX), .DIAG_W(DIAG_W)) dut (.*);

  initial assume (!rst_n);
  logic p_rst; always_ff @(posedge clk) p_rst <= rst_n;

  always @(posedge clk) begin
    cover (rst_n && consume_fire);                                   // consume
    cover (rst_n && consume_valid && !consume_ready);               // blocked consume
    cover (rst_n && return_accepted);                               // legal return
    cover (rst_n && return_valid && !return_accepted && !cfg_commit_fire); // illegal return
    cover (rst_n && consume_fire && return_accepted);              // simultaneous consume+return
    cover (rst_n && cfg_commit_fire);                              // legal atomic reconfiguration
    cover (rst_n && cfg_reject && cfg_reason == ERR_CFG_UNREP);    // non-representable rejected
    cover (rst_n && cfg_reject && cfg_reason != ERR_CFG_UNREP);    // busy/occupied rejected
    cover (rst_n && (&pool_full));                                 // all pools full
    cover (rst_n && diagnostic_clear && sticky_err);              // diagnostic clear with error set
    cover (rst_n && consume_ok_count == {DIAG_W{1'b1}});         // diagnostic saturation reached
    cover (rst_n && diagnostic_clear && (consume_fire || return_accepted)); // clear + ledger traffic
    cover (!rst_n);                                                // reset with activity possible
    cover (p_rst == 1'b0 && rst_n == 1'b1);                        // reset deasserts
  end

  // one-pool-blocks (only meaningful for N_POOLS>1)
  generate if (N_POOLS > 1) begin : g_block
    always @(posedge clk)
      cover (rst_n && consume_valid && !consume_ready
             && (available[0*COUNT_W +: COUNT_W] >= consume_amount[0*AMT_W +: AMT_W]));
  end endgenerate
endmodule
