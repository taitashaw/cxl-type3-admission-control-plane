// tb_hdm_decoder.sv
// Differential, file-driven regression for hdm_decoder + dpa_translator against
// the independent Python reference model (vectors from tb/models/gen_vectors.py).
//
// * Parameterized via `defines (NWIN/HPAW/DPAW) so the runner can sweep
//   1/2/4/8 windows and reduced/production widths.
// * Vector file via +VEC=<path> plusarg.
// * Configuration is driven SYNCHRONOUSLY (whole-vector nonblocking writes on a
//   clock edge, sampled after the next edge). This is the reviewer-recommended
//   stimulus discipline and it also sidesteps the Verilator-5.020 packed-array
//   element-write scheduling quirk entirely.
`timescale 1ns/1ps
`include "cxl_types_pkg.sv"

`ifndef NWIN
 `define NWIN 4
`endif
`ifndef HPAW
 `define HPAW 40
`endif
`ifndef DPAW
 `define DPAW 32
`endif

module tb_hdm_decoder;
  localparam int unsigned N_WIN = `NWIN;
  localparam int unsigned HPA_W = `HPAW;
  localparam int unsigned DPA_W = `DPAW;
  localparam int unsigned IDX_W = (N_WIN > 1) ? $clog2(N_WIN) : 1;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  // ---- config registers driving the decoder (whole-vector, synchronous) ---
  logic [N_WIN-1:0]              win_en_r;
  logic [N_WIN-1:0][HPA_W-1:0]  win_base_r, win_size_r;
  logic [N_WIN-1:0][DPA_W-1:0]  win_dpa_r;
  logic [DPA_W:0]               cap_r;
  logic [HPA_W-1:0]             hpa_r;

  // ---- DUT ---------------------------------------------------------------
  logic [N_WIN-1:0]             m_onehot;
  logic                         single_match, miss, overlap_reject, unaligned;
  logic [IDX_W-1:0]             win_id;
  logic [HPA_W-1:0]             m_base;
  logic [DPA_W-1:0]             m_dpa_base;
  logic                         accept, underflow, xlate_overflow, dpa_oob;
  logic [DPA_W-1:0]             dpa;

  hdm_decoder #(.HPA_W(HPA_W), .DPA_W(DPA_W), .N_WIN(N_WIN)) u_dec (
    .win_en(win_en_r), .win_base(win_base_r), .win_size(win_size_r),
    .win_dpa_base(win_dpa_r), .hpa(hpa_r),
    .match_onehot(m_onehot), .single_match(single_match), .miss(miss),
    .overlap_reject(overlap_reject), .unaligned(unaligned), .win_id(win_id),
    .matched_base(m_base), .matched_dpa_base(m_dpa_base)
  );
  dpa_translator #(.HPA_W(HPA_W), .DPA_W(DPA_W)) u_xl (
    .single_match(single_match), .unaligned(unaligned), .hpa(hpa_r),
    .matched_base(m_base), .matched_dpa_base(m_dpa_base), .dev_capacity(cap_r),
    .accept(accept), .dpa(dpa), .underflow(underflow),
    .xlate_overflow(xlate_overflow), .dpa_oob(dpa_oob)
  );

  integer fd, rc, count, i, k, errors, checks;
  integer f_nwin, f_hpaw, f_dpaw;
  string  vecfile;
  logic [HPA_W-1:0] t_base [N_WIN];
  logic [HPA_W-1:0] t_size [N_WIN];
  logic [DPA_W-1:0] t_dpa  [N_WIN];
  logic             t_en   [N_WIN];
  logic [63:0] u_hpa,u_cap,u_en,u_base,u_size,u_dpa;
  logic [63:0] e_acc,e_miss,e_ovl,e_unal,e_ovf,e_oob,e_dpa;

  initial begin
    if (!$value$plusargs("VEC=%s", vecfile)) begin
      $display("TB_RESULT: FAIL (no +VEC=<file>)"); $finish;
    end
    fd = $fopen(vecfile, "r");
    if (fd == 0) begin $display("TB_RESULT: FAIL (cannot open %s)", vecfile); $finish; end
    rc = $fscanf(fd, "%d %d %d %d", f_nwin, f_hpaw, f_dpaw, count);
    if (f_nwin!=N_WIN || f_hpaw!=HPA_W || f_dpaw!=DPA_W) begin
      $display("TB_RESULT: FAIL (param mismatch: file=%0d/%0d/%0d dut=%0d/%0d/%0d)",
               f_nwin,f_hpaw,f_dpaw,N_WIN,HPA_W,DPA_W); $finish;
    end
    errors=0; checks=0;
    $display("=== tb_hdm_decoder N_WIN=%0d HPA_W=%0d DPA_W=%0d vectors=%0d ===",
             N_WIN,HPA_W,DPA_W,count);

    for (i=0;i<count;i++) begin
      rc = $fscanf(fd, "%h %h", u_hpa, u_cap);
      for (k=0;k<N_WIN;k++) begin
        rc = $fscanf(fd, "%h %h %h %h", u_en, u_base, u_size, u_dpa);
        t_en[k]=u_en[0]; t_base[k]=u_base[HPA_W-1:0]; t_size[k]=u_size[HPA_W-1:0]; t_dpa[k]=u_dpa[DPA_W-1:0];
      end
      rc = $fscanf(fd, "%h %h %h %h %h %h %h", e_acc,e_miss,e_ovl,e_unal,e_ovf,e_oob,e_dpa);

      // synchronous drive: clocked nonblocking element writes into the
      // registered packed config (standard synchronous RTL — register-file style).
      @(posedge clk);
      for (k=0;k<N_WIN;k++) begin
        win_en_r[k]   <= t_en[k];
        win_base_r[k] <= t_base[k];
        win_size_r[k] <= t_size[k];
        win_dpa_r[k]  <= t_dpa[k];
      end
      cap_r <= u_cap[DPA_W:0];
      hpa_r <= u_hpa[HPA_W-1:0];
      @(posedge clk); #1;   // settle + into read region

      checks++;
      // Transient-immune invariants checked at the settled sample point:
      //  - classification one-hot & total
      //  - single_match <-> popcount(match_onehot)==1
      //  - no underflow ever on this path
      if (((miss + single_match + overlap_reject) !== 1) ||
          (single_match !== (($countones(m_onehot))==1))) begin
        errors++;
        if (errors<=20) $display("[FAIL] vec %0d INVARIANT miss=%b single=%b ovl=%b pc=%0d",
                                 i, miss, single_match, overlap_reject, $countones(m_onehot));
      end
      if (accept!==e_acc[0] || miss!==e_miss[0] || overlap_reject!==e_ovl[0] ||
          unaligned!==e_unal[0] || xlate_overflow!==e_ovf[0] || dpa_oob!==e_oob[0] ||
          (e_acc[0] && dpa!==e_dpa[DPA_W-1:0]) || underflow!==1'b0) begin
        errors++;
        if (errors<=20) begin
          $display("[FAIL] vec %0d hpa=%h", i, hpa_r);
          $display("   got acc=%b miss=%b ovl=%b unal=%b ovf=%b oob=%b uflow=%b dpa=%h",
                   accept,miss,overlap_reject,unaligned,xlate_overflow,dpa_oob,underflow,dpa);
          $display("   exp acc=%b miss=%b ovl=%b unal=%b ovf=%b oob=%b        dpa=%h",
                   e_acc[0],e_miss[0],e_ovl[0],e_unal[0],e_ovf[0],e_oob[0],e_dpa[DPA_W-1:0]);
        end
      end
    end
    $fclose(fd);
    $display("=== checks=%0d errors=%0d ===", checks, errors);
    $display("TB_RESULT: %s", (errors==0) ? "PASS" : "FAIL");
    $finish;
  end
endmodule
