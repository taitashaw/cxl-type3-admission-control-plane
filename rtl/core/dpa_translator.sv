// dpa_translator.sv
// Project-owned HPA -> DPA translation with widened intermediate arithmetic and
// an EXPLICIT error taxonomy. Consumes the single-match result of hdm_decoder.
//
// All address math uses at least one guard bit; the distinct conditions are
// reported separately rather than inferred from wrapped native-width compares:
//   underflow      : hpa < matched_base   (must never occur on a real match;
//                    asserted, and forces the result quiescent if it somehow does)
//   xlate_overflow : dpa >= 2**DPA_W       (DPA address-space wrap)
//   dpa_oob        : dpa >= dev_capacity   (past installed device capacity)
//
// Errors are meaningful ONLY on single_match. With no single match there is no
// translation: dpa=0, no error flags, accept=0.
`ifndef DPA_TRANSLATOR_SV
`define DPA_TRANSLATOR_SV

module dpa_translator #(
  parameter int unsigned HPA_W = 40,
  parameter int unsigned DPA_W = 32
) (
  input  logic                 single_match,     // exactly-one-match from decoder
  input  logic                 unaligned,        // decoder alignment flag
  input  logic [HPA_W-1:0]     hpa,
  input  logic [HPA_W-1:0]     matched_base,
  input  logic [DPA_W-1:0]     matched_dpa_base,
  input  logic [DPA_W:0]       dev_capacity,     // total device bytes (DPA_W+1)

  output logic                 accept,           // authorized: single & aligned & no xlate err
  output logic [DPA_W-1:0]     dpa,
  output logic                 underflow,
  output logic                 xlate_overflow,
  output logic                 dpa_oob
);

  // Guard-bit subtraction to detect underflow explicitly (hpa < base).
  localparam int unsigned OFF_W = HPA_W + 1;
  logic [OFF_W-1:0] hpa_g, base_g, offset_g;
  assign hpa_g    = {1'b0, hpa};
  assign base_g   = {1'b0, matched_base};
  assign offset_g = hpa_g - base_g;               // MSB set => underflow (borrow)
  logic uflow_raw;
  assign uflow_raw = offset_g[OFF_W-1];           // borrow bit

  // Guard-bit DPA addition.
  localparam int unsigned SUM_W = ((HPA_W > DPA_W) ? HPA_W : DPA_W) + 1;
  logic [SUM_W-1:0] dpa_full;
  assign dpa_full = {{(SUM_W-DPA_W){1'b0}}, matched_dpa_base}
                  + {{(SUM_W-OFF_W){1'b0}}, offset_g};

  logic ovf_raw, oob_raw;
  assign ovf_raw = |dpa_full[SUM_W-1:DPA_W];      // any bit >= DPA_W set
  assign oob_raw = ({1'b0, dpa_full} >= {{(SUM_W-DPA_W){1'b0}}, dev_capacity});

  // Gate everything on single_match; underflow forces quiescent as a safety net.
  logic live;
  assign live           = single_match && !uflow_raw;
  assign underflow      = single_match && uflow_raw;
  assign xlate_overflow = live && ovf_raw;
  assign dpa_oob        = live && oob_raw;
  assign dpa            = live ? dpa_full[DPA_W-1:0] : '0;
  assign accept         = live && !unaligned && !ovf_raw && !oob_raw;

`ifdef FORMAL
  // On a genuine single match the decoder guarantees hpa >= matched_base, so no
  // subtraction underflow is possible. Proved on stable states under FORMAL; the
  // testbench also checks underflow==0 at every settled sample.
  always_comb
    if (single_match) assert (!uflow_raw);
`endif
endmodule
`endif
