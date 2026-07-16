// tb_hdm_decode.sv
// Self-checking directed testbench for hdm_decoder + dpa_translator.
//
// IMPORTANT: expected values are HAND-DERIVED CONSTANTS, not recomputed with
// the DUT's own algorithm (per the project rule forbidding tests that repeat
// the implementation). Each vector below documents the manual computation.
//
// Portable across Icarus (iverilog -g2012) and Verilator. Prints a single
// "TB_RESULT: PASS|FAIL" banner the regression runner greps for.
`timescale 1ns/1ps
`include "cxl_types_pkg.sv"

module tb_hdm_decode;
  import cxl_types_pkg::*;

  localparam int unsigned HPA_W = 40;
  localparam int unsigned DPA_W = 32;
  localparam int unsigned N_WIN = 4;

  // ---- Window config ------------------------------------------------------
  // Stimulus is held in per-window SCALAR regs and concatenated into the packed
  // ports via continuous assign. This is deliberate: Verilator's --timing
  // scheduler does NOT propagate procedural blocking writes to individual
  // *elements* of a packed multidim array (proven in scratch reproducer), so
  // writing scalars + concatenating is the portable stimulus pattern that both
  // Icarus and Verilator evaluate identically. It also mirrors how a real CSR
  // block would drive these ports from discrete registers.
  logic [N_WIN-1:0]              win_en;
  logic [N_WIN-1:0][HPA_W-1:0]  win_base;
  logic [N_WIN-1:0][HPA_W-1:0]  win_size;
  logic [N_WIN-1:0][DPA_W-1:0]  win_dpa_base;
  logic [DPA_W:0]               dev_capacity;

  logic                e0,e1,e2,e3;
  logic [HPA_W-1:0]    b0,b1,b2,b3, sz0,sz1,sz2,sz3;
  logic [DPA_W-1:0]    d0,d1,d2,d3;
  assign win_en       = {e3,e2,e1,e0};
  assign win_base     = {b3,b2,b1,b0};
  assign win_size     = {sz3,sz2,sz1,sz0};
  assign win_dpa_base = {d3,d2,d1,d0};

  // ---- Lookup -------------------------------------------------------------
  logic [HPA_W-1:0]             hpa;
  cxl_op_e                      op;

  // ---- DUT outputs --------------------------------------------------------
  logic                         hit, miss, unaligned, cfg_overlap_err;
  logic [$clog2(N_WIN)-1:0]     win_id;
  logic [HPA_W-1:0]             matched_base, matched_size;
  logic [DPA_W-1:0]             matched_dpa_base;
  logic                         dpa_valid, xlate_overflow, dpa_oob;
  logic [DPA_W-1:0]             dpa;

  hdm_decoder #(.HPA_W(HPA_W), .DPA_W(DPA_W), .N_WIN(N_WIN)) u_dec (
    .win_en(win_en), .win_base(win_base), .win_size(win_size),
    .win_dpa_base(win_dpa_base), .hpa(hpa), .op(op),
    .hit(hit), .miss(miss), .unaligned(unaligned), .win_id(win_id),
    .matched_base(matched_base), .matched_size(matched_size),
    .matched_dpa_base(matched_dpa_base), .cfg_overlap_err(cfg_overlap_err)
  );

  dpa_translator #(.HPA_W(HPA_W), .DPA_W(DPA_W)) u_xl (
    .hit(hit), .hpa(hpa), .matched_base(matched_base),
    .matched_dpa_base(matched_dpa_base), .dev_capacity(dev_capacity),
    .dpa_valid(dpa_valid), .dpa(dpa),
    .xlate_overflow(xlate_overflow), .dpa_oob(dpa_oob)
  );

  integer errors = 0;
  integer checks = 0;

  // Constant-index writes only (via case) so Icarus and Verilator apply the
  // reconfiguration identically. Runtime-indexed writes into packed multidim
  // arrays are not portable across simulators.
  task set_win(input int i, input logic en,
               input logic [HPA_W-1:0] base, input logic [HPA_W-1:0] size,
               input logic [DPA_W-1:0] dbase);
    begin
      case (i)
        0: begin e0=en; b0=base; sz0=size; d0=dbase; end
        1: begin e1=en; b1=base; sz1=size; d1=dbase; end
        2: begin e2=en; b2=base; sz2=size; d2=dbase; end
        3: begin e3=en; b3=base; sz3=size; d3=dbase; end
        default: ;
      endcase
    end
  endtask

  // Drive a lookup and compare against hand-derived expectations.
  task run(input string name,
           input logic [HPA_W-1:0] a, input cxl_op_e o,
           input logic e_hit, input logic e_miss, input logic e_unal,
           input logic [$clog2(N_WIN)-1:0] e_wid,
           input logic [DPA_W-1:0] e_dpa,
           input logic e_valid, input logic e_ovf, input logic e_oob);
    begin
      hpa = a; op = o;
      #1;
      checks++;
      if (hit!==e_hit || miss!==e_miss || unaligned!==e_unal ||
          (e_hit && win_id!==e_wid) ||
          (e_valid && dpa!==e_dpa) ||
          dpa_valid!==e_valid || xlate_overflow!==e_ovf || dpa_oob!==e_oob) begin
        errors++;
        $display("  [FAIL] %-28s hpa=%010h", name, a);
        $display("         got  hit=%b miss=%b unal=%b wid=%0d dpa=%08h valid=%b ovf=%b oob=%b",
                 hit, miss, unaligned, win_id, dpa, dpa_valid, xlate_overflow, dpa_oob);
        $display("         exp  hit=%b miss=%b unal=%b wid=%0d dpa=%08h valid=%b ovf=%b oob=%b",
                 e_hit, e_miss, e_unal, e_wid, e_dpa, e_valid, e_ovf, e_oob);
      end else begin
        $display("  [pass] %-28s hpa=%010h -> dpa=%08h valid=%b", name, a, dpa, dpa_valid);
      end
    end
  endtask

  task expect_overlap(input string name, input logic e_ovl);
    begin
      #1; checks++;
      if (cfg_overlap_err !== e_ovl) begin
        errors++;
        $display("  [FAIL] %-28s cfg_overlap_err got=%b exp=%b", name, cfg_overlap_err, e_ovl);
      end else
        $display("  [pass] %-28s cfg_overlap_err=%b", name, cfg_overlap_err);
    end
  endtask

  initial begin
    $display("=== tb_hdm_decode : HDM decode + HPA->DPA translation ===");

    // ---------- Default config ----------
    // W0: [0x1_0000_0000, +0x1000_0000)  dpa 0x0000_0000   (256 MiB)
    // W1: [0x2_0000_0000, +0x0800_0000)  dpa 0x1000_0000   (128 MiB)
    // W2: DISABLED
    // W3: DISABLED
    // device capacity = 0x4000_0000 (1 GiB)
    set_win(0, 1'b1, 40'h01_0000_0000, 40'h00_1000_0000, 32'h0000_0000);
    set_win(1, 1'b1, 40'h02_0000_0000, 40'h00_0800_0000, 32'h1000_0000);
    set_win(2, 1'b0, 40'h03_0000_0000, 40'h00_1000_0000, 32'h2000_0000);
    set_win(3, 1'b0, 40'h00_0000_0000, 40'h00_0000_0000, 32'h0000_0000);
    dev_capacity = 33'h0_4000_0000;

    // T1 first valid line of W0: offset 0 -> dpa 0
    run("first_line_W0", 40'h01_0000_0000, OP_READ, 1,0,0, 0, 32'h0000_0000, 1,0,0);
    // T2 last valid line: base+size-64 = 0x1_0FFF_FFC0, offset 0x0FFF_FFC0 -> dpa 0x0FFF_FFC0
    run("last_line_W0",  40'h01_0FFF_FFC0, OP_READ, 1,0,0, 0, 32'h0FFF_FFC0, 1,0,0);
    // T3 one 64B line below base -> miss
    run("one_below_base", 40'h00_FFFF_FFC0, OP_READ, 0,1,0, 0, 32'h0, 0,0,0);
    // T4 first line at exclusive limit -> miss
    run("first_above_limit", 40'h01_1000_0000, OP_READ, 0,1,0, 0, 32'h0, 0,0,0);
    // T5 unaligned inside W0 (addr[5:0]!=0) -> hit but unaligned
    run("unaligned_in_W0", 40'h01_0000_0020, OP_READ, 1,0,1, 0, 32'h0000_0020, 1,0,0);
    // T5b same unaligned address but MAINT op -> alignment rejection bypassed
    run("unaligned_maint_bypass", 40'h01_0000_0020, OP_MAINT, 1,0,0, 0, 32'h0000_0020, 1,0,0);
    // T6 W1 mid: offset 0x0400_0000 -> dpa 0x1000_0000+0x0400_0000 = 0x1400_0000
    run("mid_W1",        40'h02_0400_0000, OP_WRITE, 1,0,0, 1, 32'h1400_0000, 1,0,0);
    // T7 disabled window range (W2) -> miss
    run("disabled_W2",   40'h03_0000_0000, OP_READ, 0,1,0, 0, 32'h0, 0,0,0);

    // ---------- T8 zero-size window rejects its own base ----------
    set_win(3, 1'b1, 40'h05_0000_0000, 40'h00_0000_0000, 32'h0000_0000);
    run("zero_size_window", 40'h05_0000_0000, OP_READ, 0,1,0, 0, 32'h0, 0,0,0);
    set_win(3, 1'b0, 40'h00_0000_0000, 40'h00_0000_0000, 32'h0000_0000);

    // ---------- T9 config: no overlap in default ----------
    expect_overlap("no_overlap_default", 1'b0);

    // ---------- T10 overlapping windows flagged ----------
    // Reconfigure W0,W1 to intentionally overlap in [0x1_1000_0000,0x1_2000_0000).
    //   W0: [0x1_0000_0000, 0x1_2000_0000) dpa 0x0000_0000
    //   W1: [0x1_1000_0000, 0x1_3000_0000) dpa 0x1000_0000
    set_win(0, 1'b1, 40'h01_0000_0000, 40'h00_2000_0000, 32'h0000_0000);
    set_win(1, 1'b1, 40'h01_1000_0000, 40'h00_2000_0000, 32'h1000_0000);
    expect_overlap("overlap_flagged", 1'b1);
    // In overlap region, W0 (index 0) wins by priority.
    // W0 offset = 0x1_1000_0000-0x1_0000_0000 = 0x1000_0000 -> dpa 0x1000_0000 (< 1 GiB cap).
    run("overlap_priority_W0", 40'h01_1000_0000, OP_READ, 1,0,0, 0, 32'h1000_0000, 1,0,0);
    // restore defaults
    set_win(0, 1'b1, 40'h01_0000_0000, 40'h00_1000_0000, 32'h0000_0000);
    set_win(1, 1'b1, 40'h02_0000_0000, 40'h00_0800_0000, 32'h1000_0000);
    expect_overlap("overlap_cleared", 1'b0);

    // ---------- T11 translation arithmetic overflow ----------
    // W3: base 0x6_0000_0000, size 0x0004_0000, dpa_base 0xFFFF_0000, cap = 2^32.
    // hpa 0x6_0002_0000 -> offset 0x2_0000 -> dpa_full 0x1_0001_0000 (bit32 set) => overflow.
    dev_capacity = 33'h1_0000_0000;
    set_win(3, 1'b1, 40'h06_0000_0000, 40'h00_0004_0000, 32'hFFFF_0000);
    run("xlate_overflow", 40'h06_0002_0000, OP_READ, 1,0,0, 3, 32'h0001_0000, 0,1,1);
    // (dpa low bits = 0x0001_0000; valid=0; overflow=1; and it is also >= cap so oob=1)

    // ---------- T12 dpa_oob WITHOUT arithmetic overflow ----------
    // cap = 1 GiB; W3 dpa_base 0x3FFF_0000, offset 0x2_0000 -> dpa 0x4001_0000 (<2^32, no ovf) >= cap.
    dev_capacity = 33'h0_4000_0000;
    set_win(3, 1'b1, 40'h06_0000_0000, 40'h00_1000_0000, 32'h3FFF_0000);
    run("dpa_oob_only", 40'h06_0002_0000, OP_READ, 1,0,0, 3, 32'h4001_0000, 0,0,1);

    // ---------- Summary ----------
    $display("=== checks=%0d errors=%0d ===", checks, errors);
    if (errors == 0) $display("TB_RESULT: PASS");
    else             $display("TB_RESULT: FAIL");
    $finish;
  end
endmodule
