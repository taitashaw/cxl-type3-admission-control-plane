// hdm_decoder.sv
// Project-owned HDM (Host-managed Device Memory) range validator.
// Combinational decode of one HPA against N configurable windows.
//
// This is a VALIDATION MODEL of address decoding — it does not implement or
// claim full CXL specification HDM decoder behaviour.
//
// Errors are split into two classes:
//   * per-request  : miss, unaligned            (depend on the presented HPA)
//   * config-level : cfg_overlap_err            (depend only on window config)
//
// Overflow-safe: window limit is computed with one extra bit so base+size that
// wraps the HPA space is compared correctly and flagged.
`ifndef HDM_DECODER_SV
`define HDM_DECODER_SV
`include "cxl_types_pkg.sv"

module hdm_decoder #(
  parameter int unsigned HPA_W  = 40,   // host physical address width
  parameter int unsigned DPA_W  = 32,   // device physical address width
  parameter int unsigned N_WIN  = 4     // number of HDM windows
) (
  // Window configuration (packed 2-D: [window][field])
  input  logic [N_WIN-1:0]              win_en,       // per-window enable
  input  logic [N_WIN-1:0][HPA_W-1:0]  win_base,     // window HPA base (64B aligned by contract)
  input  logic [N_WIN-1:0][HPA_W-1:0]  win_size,     // window size in bytes (>0)
  input  logic [N_WIN-1:0][DPA_W-1:0]  win_dpa_base, // device offset for the window

  // Lookup request
  input  logic [HPA_W-1:0]             hpa,
  input  cxl_types_pkg::cxl_op_e       op,           // maintenance ops bypass alignment rejection

  // Decode result
  output logic                         hit,
  output logic                         miss,
  output logic                         unaligned,
  output logic [$clog2(N_WIN)-1:0]     win_id,
  output logic [HPA_W-1:0]             matched_base,
  output logic [HPA_W-1:0]             matched_size,
  output logic [DPA_W-1:0]             matched_dpa_base,

  // Config-level diagnostic (independent of hpa)
  output logic                         cfg_overlap_err
);

  import cxl_types_pkg::*;

  // ---- Per-window bounds (hoisted to module-scope arrays so both the match
  //      and the overlap check share portable continuous-assign values; no
  //      block-local decls inside always_comb -> Icarus + Verilator agree) ----
  logic [N_WIN-1:0] win_match;
  logic [HPA_W:0]   hpa_ext;
  logic [HPA_W:0]   win_lo [N_WIN];   // inclusive base (guard bit)
  logic [HPA_W:0]   win_hi [N_WIN];   // exclusive limit (guard bit)
  assign hpa_ext = {1'b0, hpa};

  genvar gi;
  generate
    for (gi = 0; gi < N_WIN; gi++) begin : g_bounds
      assign win_lo[gi]    = {1'b0, win_base[gi]};
      assign win_hi[gi]    = {1'b0, win_base[gi]} + {1'b0, win_size[gi]};
      assign win_match[gi] = win_en[gi] && (hpa_ext >= win_lo[gi]) && (hpa_ext < win_hi[gi]);
    end
  endgenerate

  // ---- Priority encode: lowest index wins ---------------------------------
  logic                     any_hit;
  logic [$clog2(N_WIN)-1:0] sel;
  always_comb begin
    any_hit = 1'b0;
    sel     = '0;
    for (int i = N_WIN-1; i >= 0; i--) begin
      if (win_match[i]) begin
        any_hit = 1'b1;
        sel     = i[$clog2(N_WIN)-1:0];
      end
    end
  end

  // Maintenance / error-test transactions may deliberately target sub-line
  // addresses, so alignment is only *rejected* for normal read/write ops.
  assign unaligned        = (op != OP_MAINT) &&
                            !is_line_aligned({{(64-HPA_W){1'b0}}, hpa});
  assign hit              = any_hit;
  assign miss             = !any_hit;
  assign win_id           = sel;
  assign matched_base     = win_base[sel];
  assign matched_size     = win_size[sel];
  assign matched_dpa_base = win_dpa_base[sel];

  // ---- Config-level overlap detection (all enabled pairs) ------------------
  // Two enabled windows i<j overlap iff lo_i < hi_j AND lo_j < hi_i.
  // Built with CONSTANT generate indices only (no runtime index into unpacked
  // arrays inside always_comb) so Icarus and Verilator evaluate it identically
  // and it is directly synthesizable.
  logic [N_WIN*N_WIN-1:0] pair_ovl;
  genvar oi, oj;
  generate
    for (oi = 0; oi < N_WIN; oi++) begin : g_ovi
      for (oj = 0; oj < N_WIN; oj++) begin : g_ovj
        if (oi < oj) begin : g_pair
          // Inline the bounds from the packed ports (constant indices) rather
          // than reading the unpacked win_lo/win_hi arrays here.
          wire [HPA_W:0] lo_i = {1'b0, win_base[oi]};
          wire [HPA_W:0] lo_j = {1'b0, win_base[oj]};
          wire [HPA_W:0] hi_i = {1'b0, win_base[oi]} + {1'b0, win_size[oi]};
          wire [HPA_W:0] hi_j = {1'b0, win_base[oj]} + {1'b0, win_size[oj]};
          assign pair_ovl[oi*N_WIN + oj] =
              win_en[oi] && win_en[oj] && (lo_i < hi_j) && (lo_j < hi_i);
        end else begin : g_nopair
          assign pair_ovl[oi*N_WIN + oj] = 1'b0;
        end
      end
    end
  endgenerate
  assign cfg_overlap_err = |pair_ovl;

`ifndef SYNTHESIS
  // Assertion: a hit must never coincide with a miss (mutual exclusion).
  always_comb begin
    if (hit && miss) $error("hdm_decoder: hit && miss asserted simultaneously");
  end
`endif

endmodule
`endif
