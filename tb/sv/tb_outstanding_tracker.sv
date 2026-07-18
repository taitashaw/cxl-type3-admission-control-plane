// tb_outstanding_tracker.sv
// Differential, file-driven regression for outstanding_tracker vs the independent
// Python model (tb/models/gen_tracker_vectors.py). One vector = one cycle:
// inputs are driven at negedge; all outputs are sampled and compared against the
// model's prediction for that cycle; the intervening posedge advances DUT state.
`timescale 1ns/1ps

`ifndef DEPTH
 `define DEPTH 8
`endif
`ifndef GENW
 `define GENW 4
`endif
`ifndef EPOCHW
 `define EPOCHW 16
`endif
`ifndef OPW
 `define OPW 2
`endif
`ifndef METAW
 `define METAW 16
`endif
`ifndef TSW
 `define TSW 8
`endif
`ifndef CREDITW
 `define CREDITW 16
`endif

module tb_outstanding_tracker;
  localparam int unsigned DEPTH   = `DEPTH;
  localparam int unsigned GEN_W   = `GENW;
  localparam int unsigned EPOCH_W = `EPOCHW;
  localparam int unsigned OP_W    = `OPW;
  localparam int unsigned META_W  = `METAW;
  localparam int unsigned TS_W    = `TSW;
  localparam int unsigned CREDIT_W= `CREDITW;
  localparam int unsigned SLOT_W  = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
  localparam int unsigned TAG_W   = GEN_W + SLOT_W;
  localparam int unsigned OCC_W   = SLOT_W + 1;

  logic clk = 0; always #5 clk = ~clk;
  logic rst_n;

  logic [TS_W-1:0]    current_ts, timeout_thresh;
  logic               timeout_enable;
  logic               alloc_req;
  logic [EPOCH_W-1:0] alloc_epoch;
  logic [OP_W-1:0]    alloc_op;
  logic [META_W-1:0]  alloc_meta;
  logic [CREDIT_W-1:0] alloc_credit_vec;
  logic               alloc_gnt, full;
  logic [TAG_W-1:0]   alloc_tag;
  logic [SLOT_W-1:0]  alloc_slot;
  logic               resp_valid, resp_retire;
  logic [TAG_W-1:0]   resp_tag;
  logic [2:0]         resp_class;
  logic [EPOCH_W-1:0] retired_epoch;
  logic [OP_W-1:0]    retired_op;
  logic [META_W-1:0]  retired_meta;
  logic               retire_commit_fire, reclaim_commit_fire;
  logic [CREDIT_W-1:0] retire_commit_credit_vec, reclaim_commit_credit_vec;
  logic [EPOCH_W-1:0] retire_commit_epoch, reclaim_commit_epoch;
  logic [META_W-1:0]  retire_commit_meta, reclaim_commit_meta;
  logic               reclaim_req_valid, reclaim_req_ready;
  logic [TAG_W-1:0]   reclaim_tag;
  logic               reclaim_rsp_valid, reclaim_rsp_ready;
  logic [TAG_W-1:0]   reclaim_rsp_tag;
  logic [2:0]         reclaim_rsp_class;
  logic [META_W-1:0]  reclaim_rsp_meta;
  logic [OCC_W-1:0]   occupancy, high_watermark, quarantined_count;
  logic               timeout_any, err_sticky;
  logic [2:0]         err_first_class;
  logic [31:0]        alloc_count, retire_count, full_count, timeout_count, reclaim_count,
                      invalid_slot_count, non_live_count, stale_gen_count;
  logic [DEPTH-1:0]           dbg_live;
  logic [DEPTH*CREDIT_W-1:0]  dbg_credit_vec;
  logic [DEPTH*EPOCH_W-1:0]   dbg_epoch;

  outstanding_tracker #(.DEPTH(DEPTH), .GEN_W(GEN_W), .EPOCH_W(EPOCH_W),
                        .OP_W(OP_W), .META_W(META_W), .TS_W(TS_W), .CREDIT_W(CREDIT_W)) dut (.*);

  integer fd, rc, count, i, errors, checks;
  integer f_d,f_g,f_e,f_o,f_m,f_t;
  string  vecfile;
  logic [63:0] i_ts,i_ten,i_th,i_areq,i_aep,i_aop,i_ame,i_acv,i_rv,i_rt,i_rcq,i_rcs,i_rcrdy;
  integer f_c;
  localparam int NOUT = 36;
  logic [63:0] e[NOUT];   // expected outputs

  task chk(input string nm, input logic [63:0] got, input logic [63:0] exp, input int w);
    logic [63:0] gm, em;
    begin
      gm = got & ((w>=64)?64'hFFFFFFFFFFFFFFFF:((64'd1<<w)-1));
      em = exp & ((w>=64)?64'hFFFFFFFFFFFFFFFF:((64'd1<<w)-1));
      if (gm !== em) begin
        errors++;
        if (errors<=25) $display("   [FAIL] cyc %0d %-18s got=%h exp=%h", i, nm, gm, em);
      end
    end
  endtask

  initial begin
    if (!$value$plusargs("VEC=%s", vecfile)) begin $display("TB_RESULT: FAIL (no +VEC)"); $finish; end
    fd = $fopen(vecfile,"r");
    if (fd==0) begin $display("TB_RESULT: FAIL (open)"); $finish; end
    rc = $fscanf(fd,"%d %d %d %d %d %d %d %d", f_d,f_g,f_e,f_o,f_m,f_t,f_c,count);
    if (f_d!=DEPTH||f_g!=GEN_W||f_e!=EPOCH_W||f_o!=OP_W||f_m!=META_W||f_t!=TS_W||f_c!=CREDIT_W) begin
      $display("TB_RESULT: FAIL (param mismatch %0d/%0d/%0d/%0d/%0d/%0d/%0d)",f_d,f_g,f_e,f_o,f_m,f_t,f_c); $finish; end
    errors=0; checks=0;
    $display("=== tb_outstanding_tracker DEPTH=%0d GEN_W=%0d cycles=%0d ===", DEPTH, GEN_W, count);

    // reset
    current_ts=0; timeout_enable=0; timeout_thresh=0; alloc_req=0; alloc_epoch=0; alloc_op=0; alloc_meta=0; alloc_credit_vec=0;
    resp_valid=0; resp_tag=0; reclaim_req_valid=0; reclaim_tag=0; reclaim_rsp_ready=0;
    rst_n=0; repeat(3) @(negedge clk); rst_n=1;

    for (i=0;i<count;i++) begin
      @(negedge clk);
      rc = $fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h %h",
                   i_ts,i_ten,i_th,i_areq,i_aep,i_aop,i_ame,i_acv,i_rv,i_rt,i_rcq,i_rcs,i_rcrdy);
      for (int j=0;j<NOUT;j++) rc = $fscanf(fd,"%h", e[j]);
      current_ts=i_ts[TS_W-1:0]; timeout_enable=i_ten[0]; timeout_thresh=i_th[TS_W-1:0];
      alloc_req=i_areq[0]; alloc_epoch=i_aep[EPOCH_W-1:0]; alloc_op=i_aop[OP_W-1:0]; alloc_meta=i_ame[META_W-1:0];
      alloc_credit_vec=i_acv[CREDIT_W-1:0];
      resp_valid=i_rv[0]; resp_tag=i_rt[TAG_W-1:0];
      reclaim_req_valid=i_rcq[0]; reclaim_tag=i_rcs[TAG_W-1:0]; reclaim_rsp_ready=i_rcrdy[0];
      #1;
      checks++;
      // compare in the same field order the generator emitted
      chk("alloc_gnt",     alloc_gnt,          e[0],  1);
      chk("alloc_tag",     alloc_tag,          e[1],  TAG_W);
      chk("alloc_slot",    alloc_slot,         e[2],  SLOT_W);
      chk("full",          full,               e[3],  1);
      chk("resp_retire",   resp_retire,        e[4],  1);
      chk("resp_class",    resp_class,         e[5],  3);
      chk("retired_epoch", retired_epoch,      e[6],  EPOCH_W);
      chk("retired_op",    retired_op,         e[7],  OP_W);
      chk("retired_meta",  retired_meta,       e[8],  META_W);
      chk("reclaim_req_rdy",reclaim_req_ready, e[9],  1);
      chk("reclaim_rsp_v",  reclaim_rsp_valid, e[10], 1);
      chk("reclaim_rsp_tag",reclaim_rsp_tag,   e[11], TAG_W);
      chk("reclaim_rsp_cls",reclaim_rsp_class, e[12], 3);
      chk("reclaim_rsp_meta",reclaim_rsp_meta, e[13], META_W);
      chk("ret_commit_fire",retire_commit_fire,        e[14], 1);
      chk("ret_commit_cv",  retire_commit_credit_vec,  e[15], CREDIT_W);
      chk("ret_commit_ep",  retire_commit_epoch,       e[16], EPOCH_W);
      chk("ret_commit_meta",retire_commit_meta,        e[17], META_W);
      chk("rcl_commit_fire",reclaim_commit_fire,       e[18], 1);
      chk("rcl_commit_cv",  reclaim_commit_credit_vec, e[19], CREDIT_W);
      chk("rcl_commit_ep",  reclaim_commit_epoch,      e[20], EPOCH_W);
      chk("rcl_commit_meta",reclaim_commit_meta,       e[21], META_W);
      chk("occupancy",     occupancy,          e[22], OCC_W);
      chk("high_watermark",high_watermark,     e[23], OCC_W);
      chk("quarantined",   quarantined_count,  e[24], OCC_W);
      chk("timeout_any",   timeout_any,        e[25], 1);
      chk("alloc_count",   alloc_count,        e[26], 32);
      chk("retire_count",  retire_count,       e[27], 32);
      chk("full_count",    full_count,         e[28], 32);
      chk("timeout_count", timeout_count,      e[29], 32);
      chk("reclaim_count", reclaim_count,      e[30], 32);
      chk("invalid_cnt",   invalid_slot_count, e[31], 32);
      chk("non_live_cnt",  non_live_count,     e[32], 32);
      chk("stale_cnt",     stale_gen_count,    e[33], 32);
      chk("err_sticky",    err_sticky,         e[34], 1);
      chk("err_first",     err_first_class,    e[35], 3);
    end
    $fclose(fd);
    $display("=== checks=%0d (fields=%0d) errors=%0d ===", checks, checks*NOUT, errors);
    $display("TB_RESULT: %s", (errors==0)?"PASS":"FAIL");
    $finish;
  end
endmodule
