// hdm_decoder.sv
// Project-owned HDM range validator — combinational decode of one HPA against
// N ACTIVE (already-committed, validated) windows.
//
// FAIL-CLOSED by construction:
//   0 matches  -> miss           (no accept)
//   1 match    -> single_match   (accept path; translation authorized)
//  >=2 matches -> overlap_reject  (no accept — never silently priority-selects)
//
// `win_id` is a DIAGNOSTIC (lowest matching index) only; it never authorizes a
// transaction on its own. Authorization is `single_match & ~unaligned` gated
// further downstream by the translator's overflow/OOB checks.
//
// No operation-type input: address decode is a pure function of the address and
// window config. (An earlier revision added an op-based alignment bypass to
// silence a lint warning — that was removed; a lint warning must not create
// protocol behavior.)
`ifndef HDM_DECODER_SV
`define HDM_DECODER_SV

module hdm_decoder #(
  parameter int unsigned HPA_W  = 40,
  parameter int unsigned DPA_W  = 32,
  parameter int unsigned N_WIN  = 4,
  // derived index width; safe for N_WIN==1 ($clog2(1)==0). Do not override.
  parameter int unsigned IDX_W  = (N_WIN > 1) ? $clog2(N_WIN) : 1
) (
  input  logic [N_WIN-1:0]              win_en,
  input  logic [N_WIN-1:0][HPA_W-1:0]  win_base,
  input  logic [N_WIN-1:0][HPA_W-1:0]  win_size,
  input  logic [N_WIN-1:0][DPA_W-1:0]  win_dpa_base,

  input  logic [HPA_W-1:0]             hpa,

  output logic [N_WIN-1:0]             match_onehot,
  output logic                         single_match, // exactly one -> accept path
  output logic                         miss,         // zero matches
  output logic                         overlap_reject,// >=2 matches (fail closed)
  output logic                         unaligned,    // hpa not 64B aligned
  output logic                         line_oob,     // 64B line spills past window limit
  output logic [IDX_W-1:0]             win_id,       // DIAGNOSTIC lowest match idx
  output logic [HPA_W-1:0]             matched_base,
  output logic [DPA_W-1:0]             matched_dpa_base
);
  localparam int unsigned LINE = 64;   // 64-byte cache line
  localparam int unsigned LINE_OFF_W = 6;   // log2(LINE)

  // ---- per-window containment (overflow-safe guard bit) -------------------
  logic [HPA_W:0] hpa_ext;
  assign hpa_ext = {1'b0, hpa};

  genvar gi;
  generate
    for (gi = 0; gi < N_WIN; gi++) begin : g_match
      logic [HPA_W:0] lo, hi;
      assign lo = {1'b0, win_base[gi]};
      assign hi = {1'b0, win_base[gi]} + {1'b0, win_size[gi]}; // exclusive, guard bit
      assign match_onehot[gi] = win_en[gi] && (hpa_ext >= lo) && (hpa_ext < hi);
    end
  endgenerate

  // ---- population count of matches (fail-closed classification) -----------
  logic [$clog2(N_WIN+1)-1:0] n_match;
  assign n_match        = $countones(match_onehot);
  assign miss           = (n_match == '0);
  assign single_match   = (n_match == 1);
  assign overlap_reject = (n_match >= 2);

  // ---- diagnostic lowest-index selector (does NOT authorize) --------------
  logic [IDX_W-1:0] sel;
  always_comb begin
    sel = '0;
    for (int i = N_WIN-1; i >= 0; i--)
      if (match_onehot[i]) sel = i[IDX_W-1:0];
  end
  assign win_id           = sel;
  assign matched_base     = win_base[sel];
  assign matched_dpa_base = win_dpa_base[sel];

  assign unaligned = (hpa[LINE_OFF_W-1:0] != '0);   // not 64B aligned

  // Full 64-byte cache-line containment: the whole line [hpa, hpa+63] must lie
  // inside the matched window, checked with a guard bit (line-end arithmetic).
  logic [HPA_W:0] matched_limit, hpa_line_end;
  assign matched_limit = {1'b0, win_base[sel]} + {1'b0, win_size[sel]};
  assign hpa_line_end  = {1'b0, hpa} + {{(HPA_W+1-7){1'b0}}, 7'(LINE-1)};
  assign line_oob      = single_match && (hpa_line_end >= matched_limit);

`ifdef FORMAL
  // Fail-closed / containment properties. Guarded to FORMAL so they are proved
  // on stable states (SymbiYosys) rather than fired on combinational transients
  // in event-driven simulation. The testbench checks the same invariants at the
  // settled sample point every vector.
  always_comb begin
    // classification is one-hot and total
    assert ((miss + single_match + overlap_reject) == 1);
    // the diagnostic win_id points at a genuine match whenever any match exists
    if (single_match || overlap_reject) assert (match_onehot[win_id]);
    // single_match <-> exactly one matching window
    assert (single_match == ($countones(match_onehot) == 1));
  end
`endif
endmodule
`endif
