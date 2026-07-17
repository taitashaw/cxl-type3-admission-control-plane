// formal_decode.sv — SymbiYosys harness proving the combinational decoder +
// translator safety properties over FREE (symbolic) configuration and address.
// Small widths keep the solver fast; the properties are width-independent.
//
// Proves (reviewer's decoder/translator property set):
//   accept -> exactly one enabled window matches
//   overlap_reject -> !accept
//   accept -> aligned (transaction 64B-aligned)
//   accept -> whole 64B line inside window (!line_oob)
//   accept -> !underflow, !xlate_overflow, !dpa_oob
//   accept -> DPA = dpa_base + (hpa - base)   (translation correctness)
module formal_decode #(
  parameter int unsigned HPA_W = 16,
  parameter int unsigned DPA_W = 12,
  parameter int unsigned N_WIN = 2
)();
  // Free (undriven) inputs become symbolic under SymbiYosys.
  logic [N_WIN-1:0]              win_en;
  logic [N_WIN-1:0][HPA_W-1:0]  win_base, win_size;
  logic [N_WIN-1:0][DPA_W-1:0]  win_dpa_base;
  logic [HPA_W-1:0]             hpa;
  logic [DPA_W:0]              dev_capacity;

  logic [N_WIN-1:0]            match_onehot;
  logic                        single_match, miss, overlap_reject, unaligned, line_oob;
  logic [$clog2(N_WIN)-1:0]    win_id;
  logic [HPA_W-1:0]            m_base;
  logic [DPA_W-1:0]            m_dpa_base;
  logic                        accept, underflow, xlate_overflow, dpa_oob;
  logic [DPA_W-1:0]            dpa;

  hdm_decoder #(.HPA_W(HPA_W), .DPA_W(DPA_W), .N_WIN(N_WIN)) u_dec (
    .win_en, .win_base, .win_size, .win_dpa_base, .hpa,
    .match_onehot, .single_match, .miss, .overlap_reject, .unaligned,
    .line_oob, .win_id, .matched_base(m_base), .matched_dpa_base(m_dpa_base)
  );
  dpa_translator #(.HPA_W(HPA_W), .DPA_W(DPA_W)) u_xl (
    .single_match, .unaligned, .line_oob, .hpa, .matched_base(m_base),
    .matched_dpa_base(m_dpa_base), .dev_capacity,
    .accept, .dpa, .underflow, .xlate_overflow, .dpa_oob
  );

  // manual popcount (avoid relying on $countones in the property layer)
  integer nm;
  always_comb begin
    nm = 0;
    for (int k = 0; k < N_WIN; k++) nm += match_onehot[k];
  end

  // expected translated dpa (accept => no overflow => exact)
  logic [DPA_W-1:0] exp_dpa;
  assign exp_dpa = m_dpa_base + (hpa - m_base);

  always_comb begin
    p_onehot:    assert (!accept || (nm == 1));
    p_ovl_nacc:  assert (!overlap_reject || !accept);
    p_aligned:   assert (!accept || !unaligned);
    p_line_in:   assert (!accept || !line_oob);
    p_bounds:    assert (!accept || (!underflow && !xlate_overflow && !dpa_oob));
    p_xlate:     assert (!accept || (dpa == exp_dpa));
    p_class:     assert ((miss + single_match + overlap_reject) == 1); // one-hot classification
  end

  // ---- COVER: demonstrate non-vacuity (each outcome is reachable) ----------
  always_comb begin
    cover (accept && single_match);        // valid single-window acceptance
    cover (miss);                          // decoder miss
    cover (overlap_reject);                // overlap rejection
    cover (single_match && unaligned);     // unaligned-line rejection
    cover (single_match && line_oob);      // HPA line crossing window limit
    cover (single_match && dpa_oob);       // DPA line crossing device capacity
    cover (single_match && xlate_overflow);// DPA-space wrap
  end
endmodule
