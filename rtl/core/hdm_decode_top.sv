// hdm_decode_top.sv
// Integrated M1 slice: registered config (hdm_config) -> combinational decode
// (hdm_decoder) -> translation (dpa_translator). The decoder reads only the
// validated ACTIVE config, so decode output is always against a stable,
// committed window set.
`ifndef HDM_DECODE_TOP_SV
`define HDM_DECODE_TOP_SV

module hdm_decode_top #(
  parameter int unsigned HPA_W  = 40,
  parameter int unsigned DPA_W  = 32,
  parameter int unsigned N_WIN  = 4,
  parameter int unsigned OCNT_W = 16,
  parameter int unsigned IDX_W = (N_WIN > 1) ? $clog2(N_WIN) : 1
) (
  input  logic                     clk,
  input  logic                     rst_n,
  // config write/commit
  input  logic                     sh_we,
  input  logic [IDX_W-1:0]         sh_idx,
  input  logic                     sh_en_i,
  input  logic [HPA_W-1:0]         sh_base_i,
  input  logic [HPA_W-1:0]         sh_size_i,
  input  logic [DPA_W-1:0]         sh_dpa_i,
  input  logic                     sh_cap_we,
  input  logic [DPA_W:0]           sh_cap_i,
  input  logic                     cfg_update_req,
  input  logic [OCNT_W-1:0]        outstanding_cnt,
  output logic                     traffic_freeze,
  output logic                     req_accept_enable,
  output logic                     cfg_update_done,
  output logic                     cfg_ok,
  output logic                     cfg_reject,
  output logic [3:0]               cfg_reason,
  output logic [15:0]              cfg_epoch,
  output logic [1:0]               cfg_state,
  output logic                     cfg_busy,
  output logic                     cfg_busy_seen,
  // decode request (combinational against active config)
  input  logic [HPA_W-1:0]         hpa,
  output logic                     accept,
  output logic                     miss,
  output logic                     overlap_reject,
  output logic                     unaligned,
  output logic                     underflow,
  output logic                     xlate_overflow,
  output logic                     dpa_oob,
  output logic [IDX_W-1:0]         win_id,
  output logic [N_WIN-1:0]         match_onehot,  // decode observability (SignalTap)
  output logic [DPA_W-1:0]         dpa
);
  logic [N_WIN-1:0]              a_en;
  logic [N_WIN-1:0][HPA_W-1:0]  a_base, a_size;
  logic [N_WIN-1:0][DPA_W-1:0]  a_dpa;
  logic [DPA_W:0]               a_cap;

  hdm_config #(.HPA_W(HPA_W), .DPA_W(DPA_W), .N_WIN(N_WIN), .OCNT_W(OCNT_W)) u_cfg (
    .clk, .rst_n, .sh_we, .sh_idx, .sh_en_i, .sh_base_i, .sh_size_i, .sh_dpa_i,
    .sh_cap_we, .sh_cap_i, .cfg_update_req, .outstanding_cnt,
    .traffic_freeze, .req_accept_enable, .cfg_update_done, .cfg_ok,
    .cfg_reject, .cfg_reason, .cfg_epoch, .cfg_state, .cfg_busy, .cfg_busy_seen,
    .win_en(a_en), .win_base(a_base), .win_size(a_size),
    .win_dpa_base(a_dpa), .dev_capacity(a_cap)
  );

  logic                         single_match, line_oob;
  logic [HPA_W-1:0]             m_base;
  logic [DPA_W-1:0]             m_dpa_base;

  hdm_decoder #(.HPA_W(HPA_W), .DPA_W(DPA_W), .N_WIN(N_WIN)) u_dec (
    .win_en(a_en), .win_base(a_base), .win_size(a_size), .win_dpa_base(a_dpa),
    .hpa(hpa), .match_onehot(match_onehot), .single_match(single_match),
    .miss(miss), .overlap_reject(overlap_reject), .unaligned(unaligned),
    .line_oob(line_oob), .win_id(win_id), .matched_base(m_base),
    .matched_dpa_base(m_dpa_base)
  );

  dpa_translator #(.HPA_W(HPA_W), .DPA_W(DPA_W)) u_xl (
    .single_match(single_match), .unaligned(unaligned), .line_oob(line_oob),
    .hpa(hpa), .matched_base(m_base), .matched_dpa_base(m_dpa_base),
    .dev_capacity(a_cap), .accept(accept), .dpa(dpa), .underflow(underflow),
    .xlate_overflow(xlate_overflow), .dpa_oob(dpa_oob)
  );
endmodule
`endif
