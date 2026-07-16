// dpa_translator.sv
// Project-owned HPA -> DPA translation with device-capacity bounds + overflow.
// Combinational. Consumes the matched window fields from hdm_decoder.
//
//   offset = hpa - matched_base            (guaranteed >= 0 when decoder hit)
//   dpa    = matched_dpa_base + offset
//
// Two INDEPENDENT error conditions:
//   xlate_overflow : dpa arithmetic exceeds DPA_W bits (address-space wrap)
//   dpa_oob        : dpa lands at/above the physical device capacity
//                    (a real, separate check from arithmetic overflow — a
//                     window can translate arithmetically yet still point past
//                     the end of the installed device).
`ifndef DPA_TRANSLATOR_SV
`define DPA_TRANSLATOR_SV

module dpa_translator #(
  parameter int unsigned HPA_W = 40,
  parameter int unsigned DPA_W = 32
) (
  input  logic                 hit,              // decoder produced a valid match
  input  logic [HPA_W-1:0]     hpa,
  input  logic [HPA_W-1:0]     matched_base,
  input  logic [DPA_W-1:0]     matched_dpa_base,
  input  logic [DPA_W:0]       dev_capacity,     // total device bytes (DPA_W+1 to allow full 2^DPA_W)

  output logic                 dpa_valid,        // hit && no translation error
  output logic [DPA_W-1:0]     dpa,
  output logic                 xlate_overflow,
  output logic                 dpa_oob
);

  // offset within window (HPA_W bits; non-negative on a real hit)
  logic [HPA_W-1:0] offset;
  assign offset = hpa - matched_base;

  // Full-width sum with guard bits to detect arithmetic overflow.
  localparam int unsigned SUM_W = ((HPA_W > DPA_W) ? HPA_W : DPA_W) + 1;
  logic [SUM_W-1:0] dpa_full;
  assign dpa_full = {{(SUM_W-DPA_W){1'b0}}, matched_dpa_base}
                  + {{(SUM_W-HPA_W){1'b0}}, offset};

  // Overflow / OOB are only meaningful on a decoder hit. With no hit there is
  // no translation, so all error flags and the dpa are forced quiescent. This
  // keeps the contract clean: !hit => {dpa=0, no xlate errors, dpa_valid=0}.
  logic ovf_raw, oob_raw;
  assign ovf_raw = |dpa_full[SUM_W-1:DPA_W];
  assign oob_raw = ({1'b0, dpa_full} >= {{(SUM_W-DPA_W){1'b0}}, dev_capacity});

  assign xlate_overflow = hit && ovf_raw;
  assign dpa_oob        = hit && oob_raw;
  assign dpa            = hit ? dpa_full[DPA_W-1:0] : '0;
  assign dpa_valid      = hit && !ovf_raw && !oob_raw;

endmodule
`endif
