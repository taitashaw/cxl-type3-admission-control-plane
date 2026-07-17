// dpa_translator.sv
// Project-owned HPA -> DPA translation with widened intermediate arithmetic and
// an EXPLICIT error taxonomy covering the COMPLETE 64-byte transaction (not just
// the starting address). Consumes the single-match result of hdm_decoder.
//
// All address math uses guard bits; the distinct conditions are reported
// separately rather than inferred from wrapped native-width compares:
//   underflow      : hpa < matched_base            (must never occur on a match)
//   line_oob       : hpa+63 >= window_limit         (from decoder; HPA line spill)
//   xlate_overflow : dpa+63 >= 2**DPA_W             (line-end wraps DPA space)
//   dpa_oob        : dpa+63 >= dev_capacity          (line-end past device)
//
// Errors are meaningful ONLY on single_match. With no single match: dpa=0, no
// error flags, accept=0.
`ifndef DPA_TRANSLATOR_SV
`define DPA_TRANSLATOR_SV

module dpa_translator #(
  parameter int unsigned HPA_W = 40,
  parameter int unsigned DPA_W = 32
) (
  input  logic                 single_match,
  input  logic                 unaligned,
  input  logic                 line_oob,         // HPA 64B line spills past window
  input  logic [HPA_W-1:0]     hpa,
  input  logic [HPA_W-1:0]     matched_base,
  input  logic [DPA_W-1:0]     matched_dpa_base,
  input  logic [DPA_W:0]       dev_capacity,     // total device bytes (DPA_W+1)

  output logic                 accept,           // single & aligned & in-bounds
  output logic [DPA_W-1:0]     dpa,
  output logic                 underflow,
  output logic                 xlate_overflow,
  output logic                 dpa_oob
);
  localparam int unsigned LINE = 64;

  // Guard-bit subtraction to detect underflow explicitly (hpa < base).
  localparam int unsigned OFF_W = HPA_W + 1;
  logic [OFF_W-1:0] hpa_g, base_g, offset_g;
  assign hpa_g    = {1'b0, hpa};
  assign base_g   = {1'b0, matched_base};
  assign offset_g = hpa_g - base_g;
  logic uflow_raw;
  assign uflow_raw = offset_g[OFF_W-1];             // borrow bit

  // Guard-bit DPA addition; +1 extra bit so the line-end (+63) cannot itself wrap.
  localparam int unsigned SUM_W = (((HPA_W > DPA_W) ? HPA_W : DPA_W) + 1);
  logic [SUM_W:0] dpa_start_full, dpa_end_full, cap_ext;
  assign dpa_start_full = {{(SUM_W+1-DPA_W){1'b0}}, matched_dpa_base}
                        + {{(SUM_W+1-OFF_W){1'b0}}, offset_g};
  assign dpa_end_full   = dpa_start_full + {{(SUM_W+1-7){1'b0}}, 7'(LINE-1)};
  assign cap_ext        = {{(SUM_W+1-(DPA_W+1)){1'b0}}, dev_capacity};

  // line-end based bounds
  logic ovf_raw, oob_raw;
  assign ovf_raw = |dpa_end_full[SUM_W:DPA_W];      // any bit at/above DPA_W set
  assign oob_raw = (dpa_end_full >= cap_ext);

  logic live;
  assign live           = single_match && !uflow_raw;
  assign underflow      = single_match && uflow_raw;
  assign xlate_overflow = live && ovf_raw;
  assign dpa_oob        = live && oob_raw;
  assign dpa            = live ? dpa_start_full[DPA_W-1:0] : '0;
  assign accept         = live && !unaligned && !line_oob && !ovf_raw && !oob_raw;

`ifdef FORMAL
  always_comb begin
    if (single_match) assert (!uflow_raw);                 // hpa >= matched_base
    if (accept)       assert (!ovf_raw && !oob_raw && !unaligned && !line_oob);
    // translation_valid => DPA start = dpa_base + (hpa - base)
    if (accept) assert (dpa == dpa_start_full[DPA_W-1:0]);
  end
`endif
endmodule
`endif
