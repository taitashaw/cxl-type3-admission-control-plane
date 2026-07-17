// formal_config.sv — small-parameter free-input wrapper around hdm_config for
// SymbiYosys. Safety ASSERTS live inside hdm_config under `ifdef FORMAL; this
// wrapper supplies free stimulus, the PUBLISHED ENVIRONMENT ASSUMPTIONS, and the
// COVER statements demonstrating non-vacuity.
//
// PUBLISHED ENVIRONMENT ASSUMPTIONS (interface contract, NOT DUT guarantees):
//   A1  While cfg_req_valid && !cfg_req_ready the requester holds cfg_req_valid
//       and the payload stable (no drop, no mutation).
//   A2  The admission path gates allocation on req_accept_enable, i.e.
//       !req_accept_enable |-> !alloc_fire. (The tracker's alloc_req is ANDed
//       with req_accept_enable in the integrated datapath.)
// Reset: initial assume(!rst_n); rst_n free afterwards (may assert/deassert).
module formal_config #(
  parameter int unsigned HPA_W  = 16,
  parameter int unsigned DPA_W  = 12,
  parameter int unsigned N_WIN  = 2,
  parameter int unsigned OCNT_W = 3,
  parameter int unsigned TS_W   = 4,
  parameter int unsigned IDX_W  = (N_WIN > 1) ? $clog2(N_WIN) : 1
)(
  input logic clk
);
  localparam logic [1:0] S_ACTIVE=0, S_FREEZE=1, S_COMMIT=2;
  localparam logic [1:0] RSP_OK=0, RSP_INVALID=1;

  logic                    rst_n;
  logic                    sh_we, sh_en_i, sh_cap_we;
  logic [IDX_W-1:0]        sh_idx;
  logic [HPA_W-1:0]        sh_base_i, sh_size_i;
  logic [DPA_W-1:0]        sh_dpa_i;
  logic [DPA_W:0]          sh_cap_i;
  logic                    cfg_req_valid, cfg_req_ready, cfg_req_timeout_en;
  logic [TS_W-1:0]         cfg_req_timeout_thresh;
  logic                    cfg_rsp_valid, cfg_rsp_ready;
  logic [1:0]              cfg_rsp_code;
  logic [3:0]              cfg_rsp_reason;
  logic [OCNT_W-1:0]       outstanding_cnt;
  logic                    alloc_fire, traffic_freeze, req_accept_enable;
  logic [15:0]             cfg_epoch;
  logic [1:0]              cfg_state;
  logic                    timeout_enable;
  logic [TS_W-1:0]         timeout_thresh;
  logic [N_WIN-1:0]              win_en;
  logic [N_WIN-1:0][HPA_W-1:0]  win_base, win_size;
  logic [N_WIN-1:0][DPA_W-1:0]  win_dpa_base;
  logic [DPA_W:0]               dev_capacity;

  hdm_config #(.HPA_W(HPA_W), .DPA_W(DPA_W), .N_WIN(N_WIN),
               .OCNT_W(OCNT_W), .TS_W(TS_W)) dut (.*);

  initial assume (!rst_n);

  logic init = 1'b0;
  logic p_req_valid, p_req_ready, p_to_en, p_rsp_valid, p_rst;
  logic [TS_W-1:0] p_to_th, p_act_th;
  logic [1:0] p_state;
  always_ff @(posedge clk) begin
    init<=1'b1; p_req_valid<=cfg_req_valid; p_req_ready<=cfg_req_ready;
    p_to_en<=cfg_req_timeout_en; p_to_th<=cfg_req_timeout_thresh;
    p_rsp_valid<=cfg_rsp_valid; p_state<=cfg_state; p_rst<=rst_n;
    p_act_th<=timeout_thresh;
  end

  // ---- A1: requester holds valid + payload stable while backpressured -------
  always @(posedge clk) begin
    if (init && p_req_valid && !p_req_ready) begin
      assume (cfg_req_valid);
      assume (cfg_req_timeout_en     == p_to_en);
      assume (cfg_req_timeout_thresh == p_to_th);
    end
  end
  // ---- A2: admission gate honoured by the environment -----------------------
  always_comb if (!req_accept_enable) assume (!alloc_fire);

  // ---- COVER: non-vacuity ---------------------------------------------------
  always @(posedge clk) begin
    cover (rst_n && cfg_req_valid && cfg_req_ready);                       // immediate accept
    cover (rst_n && init && p_req_valid && !p_req_ready
                 && cfg_req_valid && cfg_req_ready);                       // backpressured then accepted
    cover (rst_n && cfg_rsp_valid && cfg_rsp_code == RSP_INVALID);         // INVALID response
    cover (rst_n && cfg_rsp_valid && cfg_rsp_code == RSP_OK);              // freeze/drain/commit OK
    cover (rst_n && cfg_rsp_valid && !cfg_rsp_ready);                      // response backpressured
    cover (rst_n && cfg_req_valid && !cfg_req_ready && cfg_state == S_COMMIT); // req during COMMIT, held
    cover (rst_n && cfg_state == S_FREEZE && outstanding_cnt != '0);       // draining with traffic
    cover (!rst_n && p_state != S_ACTIVE);                                 // reset while processing
    cover (!rst_n && p_rsp_valid);                                         // reset with response pending
    cover (p_rst == 1'b0 && rst_n == 1'b1);                                // reset deasserts
    // timeout-threshold change committed, then a new-epoch allocation
    cover (rst_n && init && (p_state == S_COMMIT) && (timeout_thresh != p_act_th));
    cover (rst_n && timeout_enable && alloc_fire);                         // alloc under enabled timeout
  end
endmodule
