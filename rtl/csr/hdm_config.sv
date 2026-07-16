// hdm_config.sv
// Registered HDM window configuration with atomic, validated commit.
//
// Model: SHADOW registers (freely written) -> validate on `commit` -> if valid
// AND the datapath is drained (outstanding_cnt == 0) -> copy shadow to ACTIVE
// registers atomically and bump the config epoch. Otherwise the commit is
// REJECTED with a reason code and the ACTIVE config is left untouched.
//
// This eliminates ambiguous partial/mid-flight configuration and gives the
// decoder a stable, validated ACTIVE config to read. Reason codes match the
// independent Python reference model (tb/models/hdm_model.py).
`ifndef HDM_CONFIG_SV
`define HDM_CONFIG_SV
`include "cxl_types_pkg.sv"

module hdm_config #(
  parameter int unsigned HPA_W = 40,
  parameter int unsigned DPA_W = 32,
  parameter int unsigned N_WIN = 4,
  parameter int unsigned OCNT_W = 16,
  parameter int unsigned IDX_W = (N_WIN > 1) ? $clog2(N_WIN) : 1  // derived; do not override
) (
  input  logic                       clk,
  input  logic                       rst_n,

  // Shadow write port (one window per write)
  input  logic                       sh_we,
  input  logic [IDX_W-1:0]           sh_idx,
  input  logic                       sh_en_i,
  input  logic [HPA_W-1:0]           sh_base_i,
  input  logic [HPA_W-1:0]           sh_size_i,
  input  logic [DPA_W-1:0]           sh_dpa_i,
  input  logic                       sh_cap_we,
  input  logic [DPA_W:0]             sh_cap_i,

  // Commit protocol
  input  logic                       commit,          // 1-cycle pulse
  input  logic [OCNT_W-1:0]          outstanding_cnt, // from tracker; 0 == drained
  output logic                       cfg_committed,   // pulse: active updated
  output logic                       cfg_reject,      // pulse: commit refused
  output logic [3:0]                 cfg_reason,      // reason for last commit attempt
  output logic [15:0]                cfg_epoch,       // increments per successful commit

  // Active (validated) configuration for the decoder
  output logic [N_WIN-1:0]           win_en,
  output logic [N_WIN-1:0][HPA_W-1:0] win_base,
  output logic [N_WIN-1:0][HPA_W-1:0] win_size,
  output logic [N_WIN-1:0][DPA_W-1:0] win_dpa_base,
  output logic [DPA_W:0]             dev_capacity
);
  import cxl_types_pkg::*;

  // reason codes (match hdm_model.py)
  localparam logic [3:0] CFG_OK=0, CFG_ZERO_SIZE=1, CFG_BASE_ALIGN=2, CFG_SIZE_ALIGN=3,
                         CFG_DPA_ALIGN=4, CFG_HPA_OVF=5, CFG_DPA_OVF=6, CFG_CAP_EXCEED=7,
                         CFG_OVERLAP=8, CFG_BUSY=9;

  // ---- shadow + active storage (unpacked for portable element writes) -----
  logic              sh_en   [N_WIN];
  logic [HPA_W-1:0]  sh_base [N_WIN];
  logic [HPA_W-1:0]  sh_size [N_WIN];
  logic [DPA_W-1:0]  sh_dpa  [N_WIN];
  logic [DPA_W:0]    sh_cap;

  logic              act_en   [N_WIN];
  logic [HPA_W-1:0]  act_base [N_WIN];
  logic [HPA_W-1:0]  act_size [N_WIN];
  logic [DPA_W-1:0]  act_dpa  [N_WIN];
  logic [DPA_W:0]    act_cap;

  // pack active -> ports
  genvar gp;
  generate
    for (gp = 0; gp < N_WIN; gp++) begin : g_pack
      assign win_en[gp]       = act_en[gp];
      assign win_base[gp]     = act_base[gp];
      assign win_size[gp]     = act_size[gp];
      assign win_dpa_base[gp] = act_dpa[gp];
    end
  endgenerate
  assign dev_capacity = act_cap;

  // ---- combinational validation of the SHADOW config ----------------------
  // Per-window reason (priority order matches the reference model).
  localparam int unsigned WSUM = ((HPA_W > DPA_W) ? HPA_W : DPA_W) + 1;
  logic [3:0] win_reason [N_WIN];
  genvar gv;
  generate
    for (gv = 0; gv < N_WIN; gv++) begin : g_val
      logic [HPA_W:0]   hsum;   // base+size, guard bit
      logic [WSUM-1:0]  dsum;   // dpa_base+size at FULL width (size can exceed DPA_W)
      assign hsum = {1'b0, sh_base[gv]} + {1'b0, sh_size[gv]};
      assign dsum = {{(WSUM-DPA_W){1'b0}}, sh_dpa[gv]}
                  + {{(WSUM-HPA_W){1'b0}}, sh_size[gv]};
      // Continuous-assign priority chain (constant genvar index -> portable).
      assign win_reason[gv] =
          (!sh_en[gv])                                   ? CFG_OK        :
          (sh_size[gv] == '0)                            ? CFG_ZERO_SIZE :
          (sh_base[gv][5:0] != '0)                       ? CFG_BASE_ALIGN:
          (sh_size[gv][5:0] != '0)                       ? CFG_SIZE_ALIGN:
          (sh_dpa[gv][5:0]  != '0)                       ? CFG_DPA_ALIGN :
          (hsum > {1'b1, {HPA_W{1'b0}}})                             ? CFG_HPA_OVF   :
          (dsum > {{(WSUM-DPA_W-1){1'b0}}, 1'b1, {DPA_W{1'b0}}})      ? CFG_DPA_OVF   :
          (dsum > {{(WSUM-DPA_W-1){1'b0}}, sh_cap})      ? CFG_CAP_EXCEED:
                                                           CFG_OK;
    end
  endgenerate

  // lowest-index enabled window with a nonzero reason
  logic [3:0] first_win_reason;
  always_comb begin
    first_win_reason = CFG_OK;
    for (int i = N_WIN-1; i >= 0; i--)
      if (win_reason[i] != CFG_OK) first_win_reason = win_reason[i];
  end

  // pairwise overlap among enabled shadow windows (constant-index generate)
  logic [N_WIN*N_WIN-1:0] pair_ovl;
  genvar oi, oj;
  generate
    for (oi = 0; oi < N_WIN; oi++) begin : g_oi
      for (oj = 0; oj < N_WIN; oj++) begin : g_oj
        if (oi < oj) begin : g_pair
          wire [HPA_W:0] loi = {1'b0, sh_base[oi]};
          wire [HPA_W:0] loj = {1'b0, sh_base[oj]};
          wire [HPA_W:0] hii = {1'b0, sh_base[oi]} + {1'b0, sh_size[oi]};
          wire [HPA_W:0] hij = {1'b0, sh_base[oj]} + {1'b0, sh_size[oj]};
          assign pair_ovl[oi*N_WIN+oj] = sh_en[oi] && sh_en[oj] && (loi < hij) && (loj < hii);
        end else begin : g_np
          assign pair_ovl[oi*N_WIN+oj] = 1'b0;
        end
      end
    end
  endgenerate
  logic overlap_bad;
  assign overlap_bad = |pair_ovl;

  // overall shadow verdict
  logic [3:0] shadow_reason;
  logic       shadow_valid;
  always_comb begin
    if (first_win_reason != CFG_OK) shadow_reason = first_win_reason;
    else if (overlap_bad)           shadow_reason = CFG_OVERLAP;
    else                            shadow_reason = CFG_OK;
    shadow_valid = (shadow_reason == CFG_OK);
  end

  // ---- sequential: shadow writes + atomic commit --------------------------
  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (k = 0; k < N_WIN; k++) begin
        sh_en[k]<=1'b0; sh_base[k]<='0; sh_size[k]<='0; sh_dpa[k]<='0;
        act_en[k]<=1'b0; act_base[k]<='0; act_size[k]<='0; act_dpa[k]<='0;
      end
      sh_cap<='0; act_cap<='0;
      cfg_committed<=1'b0; cfg_reject<=1'b0; cfg_reason<=CFG_OK; cfg_epoch<='0;
    end else begin
      cfg_committed <= 1'b0;
      cfg_reject    <= 1'b0;

      if (sh_we) begin
        sh_en[sh_idx]   <= sh_en_i;
        sh_base[sh_idx] <= sh_base_i;
        sh_size[sh_idx] <= sh_size_i;
        sh_dpa[sh_idx]  <= sh_dpa_i;
      end
      if (sh_cap_we) sh_cap <= sh_cap_i;

      if (commit) begin
        if (outstanding_cnt != '0) begin
          // datapath not drained -> refuse (drain required)
          cfg_reject <= 1'b1;
          cfg_reason <= CFG_BUSY;
        end else if (shadow_valid) begin
          for (k = 0; k < N_WIN; k++) begin
            act_en[k]   <= sh_en[k];
            act_base[k] <= sh_base[k];
            act_size[k] <= sh_size[k];
            act_dpa[k]  <= sh_dpa[k];
          end
          act_cap       <= sh_cap;
          cfg_epoch     <= cfg_epoch + 16'd1;
          cfg_committed <= 1'b1;
          cfg_reason    <= CFG_OK;
        end else begin
          cfg_reject <= 1'b1;
          cfg_reason <= shadow_reason;
        end
      end
    end
  end
endmodule
`endif
