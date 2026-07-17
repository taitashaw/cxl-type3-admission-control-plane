// formal_config.sv — small-parameter free-input wrapper around hdm_config for
// SymbiYosys. The SAFETY ASSERTS live inside hdm_config under `ifdef FORMAL`
// (they need internal snapshot/state access); this wrapper supplies free
// stimulus and the COVER statements that demonstrate non-vacuity.
//
// Reset discipline: `initial assume(!rst_n)` gives a defined start in reset;
// thereafter rst_n is FREE, so it may deassert (needed for the useful covers)
// and re-assert (needed for the reset-from-each-state covers). No input is
// constrained to force the asserted behavior.
module formal_config #(
  parameter int unsigned HPA_W = 16,
  parameter int unsigned DPA_W = 12,
  parameter int unsigned N_WIN = 2,
  parameter int unsigned OCNT_W = 3,
  parameter int unsigned IDX_W = (N_WIN > 1) ? $clog2(N_WIN) : 1
)(
  input logic clk
);
  localparam logic [1:0] S_ACTIVE=0, S_FREEZE=1, S_COMMIT=2;

  logic                    rst_n;
  logic                    sh_we, sh_en_i, sh_cap_we, cfg_update_req;
  logic [IDX_W-1:0]        sh_idx;
  logic [HPA_W-1:0]        sh_base_i, sh_size_i;
  logic [DPA_W-1:0]        sh_dpa_i;
  logic [DPA_W:0]          sh_cap_i;
  logic [OCNT_W-1:0]       outstanding_cnt;
  logic                    traffic_freeze, req_accept_enable, cfg_update_done, cfg_ok, cfg_reject;
  logic [3:0]              cfg_reason;
  logic [15:0]             cfg_epoch;
  logic [1:0]              cfg_state;
  logic [N_WIN-1:0]              win_en;
  logic [N_WIN-1:0][HPA_W-1:0]  win_base, win_size;
  logic [N_WIN-1:0][DPA_W-1:0]  win_dpa_base;
  logic [DPA_W:0]               dev_capacity;

  hdm_config #(.HPA_W(HPA_W), .DPA_W(DPA_W), .N_WIN(N_WIN), .OCNT_W(OCNT_W)) dut (.*);

  initial assume (!rst_n);   // defined start in reset; rst_n free afterwards

  // previous FSM state (for transition covers)
  logic [1:0] p_state;
  logic       p_rst_n;
  always_ff @(posedge clk) begin p_state <= cfg_state; p_rst_n <= rst_n; end

  // ---- COVER: prove the harness reaches the interesting states -------------
  always @(posedge clk) begin
    cover (rst_n && cfg_state == S_FREEZE);                       // ACTIVE -> FREEZE
    cover (rst_n && cfg_state == S_FREEZE && outstanding_cnt != '0); // DRAIN, traffic present
    cover (rst_n && cfg_state == S_COMMIT);                       // FREEZE -> COMMIT
    cover (rst_n && cfg_ok);                                      // successful commit / epoch++
    cover (rst_n && cfg_reject);                                  // invalid config rejected
    cover (rst_n && p_state != S_ACTIVE && cfg_state == S_ACTIVE);// COMMIT/reset -> ACTIVE
    cover (rst_n && cfg_update_req && req_accept_enable);         // concurrent update + admission
    cover (!rst_n && p_state == S_ACTIVE);                        // reset from ACTIVE
    cover (!rst_n && p_state == S_FREEZE);                        // reset from FREEZE
    cover (!rst_n && p_state == S_COMMIT);                        // reset from COMMIT
    cover (p_rst_n == 1'b0 && rst_n == 1'b1);                     // reset deasserts (liveness of covers)
  end
endmodule
