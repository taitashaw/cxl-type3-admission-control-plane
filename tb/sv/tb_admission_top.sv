// tb_admission_top.sv — differential, file-driven regression for admission_top vs
// the independent Python model (tb/models/gen_admission_vectors.py). One vector =
// one cycle: inputs driven at negedge, outputs sampled and compared, posedge
// advances state.
`timescale 1ns/1ps
`ifndef NPOOLS
 `define NPOOLS 2
`endif
`ifndef AMTW
 `define AMTW 3
`endif
`ifndef COUNTW
 `define COUNTW 6
`endif
`ifndef RESETMAX
 `define RESETMAX 8
`endif
`ifndef DEPTH
 `define DEPTH 4
`endif
`ifndef GENW
 `define GENW 4
`endif
`ifndef EPOCHW
 `define EPOCHW 8
`endif
`ifndef OPW
 `define OPW 2
`endif
`ifndef METAW
 `define METAW 8
`endif
`ifndef TSW
 `define TSW 8
`endif

module tb_admission_top;
  localparam int unsigned N_POOLS = `NPOOLS;
  localparam int unsigned AMT_W   = `AMTW;
  localparam int unsigned COUNT_W = `COUNTW;
  localparam int unsigned RESET_MAX = `RESETMAX;
  localparam int unsigned DEPTH   = `DEPTH;
  localparam int unsigned GEN_W   = `GENW;
  localparam int unsigned EPOCH_W = `EPOCHW;
  localparam int unsigned OP_W    = `OPW;
  localparam int unsigned META_W  = `METAW;
  localparam int unsigned TS_W    = `TSW;
  localparam int unsigned CREDIT_VEC_W = N_POOLS*AMT_W;
  localparam int unsigned SLOT_W  = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
  localparam int unsigned TAG_W   = GEN_W + SLOT_W;
  localparam int unsigned OCC_W   = SLOT_W + 1;

  logic clk = 0; always #5 clk = ~clk;
  logic rst_n;

  logic [TS_W-1:0]       current_ts, timeout_thresh;
  logic                  timeout_enable;
  logic [EPOCH_W-1:0]    active_epoch;
  logic                  req_valid, req_accept_enable;
  logic [OP_W-1:0]       req_op;
  logic [META_W-1:0]     req_meta;
  logic [CREDIT_VEC_W-1:0] req_credit_vec;
  logic                  req_ready, req_accept;
  logic [TAG_W-1:0]      issued_tag;
  logic                  downstream_ready, issue_valid;
  logic [TAG_W-1:0]      issue_tag;
  logic                  resp_valid; logic [TAG_W-1:0] resp_tag;
  logic                  resp_retire; logic [2:0] resp_class;
  logic [EPOCH_W-1:0]    retired_epoch;
  logic                  reclaim_req_valid, reclaim_req_ready;
  logic [TAG_W-1:0]      reclaim_tag;
  logic                  reclaim_rsp_valid, reclaim_rsp_ready;
  logic [TAG_W-1:0]      reclaim_rsp_tag; logic [2:0] reclaim_rsp_class;
  logic                  tracker_alloc_fire, credit_consume_fire, issue_enqueue;
  logic                  credit_return_valid, credit_return_accepted;
  logic [N_POOLS*COUNT_W-1:0] used, available;
  logic [OCC_W-1:0]      occupancy;

  admission_top #(.N_POOLS(N_POOLS), .AMT_W(AMT_W), .COUNT_W(COUNT_W), .RESET_MAX(RESET_MAX),
                  .DEPTH(DEPTH), .GEN_W(GEN_W), .EPOCH_W(EPOCH_W), .OP_W(OP_W),
                  .META_W(META_W), .TS_W(TS_W)) dut (.*);

  integer fd, rc, count, i, errors, checks;
  integer h_np,h_aw,h_cw,h_rm,h_d,h_g,h_e,h_o,h_m,h_t;
  string vecfile;
  localparam int NSCAL = 18;
  localparam int NOUT  = NSCAL + 2*N_POOLS;
  logic [63:0] iv[15];
  logic [63:0] e[NOUT];

  task chk(input string nm, input logic [63:0] got, input logic [63:0] exp, input int w);
    logic [63:0] gm, em;
    begin
      gm = got & ((w>=64)?64'hFFFFFFFFFFFFFFFF:((64'd1<<w)-1));
      em = exp & ((w>=64)?64'hFFFFFFFFFFFFFFFF:((64'd1<<w)-1));
      if (gm !== em) begin
        errors++;
        if (errors<=25) $display("   [FAIL] cyc %0d %-20s got=%h exp=%h", i, nm, gm, em);
      end
    end
  endtask

  initial begin
    if (!$value$plusargs("VEC=%s", vecfile)) begin $display("TB_RESULT: FAIL (no +VEC)"); $finish; end
    fd = $fopen(vecfile,"r");
    if (fd==0) begin $display("TB_RESULT: FAIL (open)"); $finish; end
    rc = $fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d",
                 h_np,h_aw,h_cw,h_rm,h_d,h_g,h_e,h_o,h_m,h_t,count);
    if (h_np!=N_POOLS||h_aw!=AMT_W||h_cw!=COUNT_W||h_rm!=RESET_MAX||h_d!=DEPTH||h_g!=GEN_W
        ||h_e!=EPOCH_W||h_o!=OP_W||h_m!=META_W||h_t!=TS_W) begin
      $display("TB_RESULT: FAIL (param mismatch)"); $finish; end
    errors=0; checks=0;
    $display("=== tb_admission_top NP=%0d AW=%0d CW=%0d DEPTH=%0d cycles=%0d ===",
             N_POOLS, AMT_W, COUNT_W, DEPTH, count);

    current_ts=0; timeout_enable=0; timeout_thresh=0; active_epoch=0; req_valid=0;
    req_accept_enable=0; req_op=0; req_meta=0; req_credit_vec=0; downstream_ready=0;
    resp_valid=0; resp_tag=0; reclaim_req_valid=0; reclaim_tag=0; reclaim_rsp_ready=0;
    rst_n=0; repeat(3) @(negedge clk); rst_n=1;

    for (i=0;i<count;i++) begin
      @(negedge clk);
      for (int j=0;j<15;j++) rc = $fscanf(fd,"%h", iv[j]);
      for (int j=0;j<NOUT;j++) rc = $fscanf(fd,"%h", e[j]);
      current_ts=iv[0][TS_W-1:0]; timeout_enable=iv[1][0]; timeout_thresh=iv[2][TS_W-1:0];
      active_epoch=iv[3][EPOCH_W-1:0]; req_valid=iv[4][0]; req_accept_enable=iv[5][0];
      req_op=iv[6][OP_W-1:0]; req_meta=iv[7][META_W-1:0]; req_credit_vec=iv[8][CREDIT_VEC_W-1:0];
      downstream_ready=iv[9][0]; resp_valid=iv[10][0]; resp_tag=iv[11][TAG_W-1:0];
      reclaim_req_valid=iv[12][0]; reclaim_tag=iv[13][TAG_W-1:0]; reclaim_rsp_ready=iv[14][0];
      #1;
      checks++;
      chk("req_ready",       req_ready,             e[0],  1);
      chk("req_accept",      req_accept,            e[1],  1);
      chk("alloc_fire",      tracker_alloc_fire,    e[2],  1);
      chk("consume_fire",    credit_consume_fire,   e[3],  1);
      chk("issue_enqueue",   issue_enqueue,         e[4],  1);
      chk("issue_valid",     issue_valid,           e[5],  1);
      chk("issued_tag",      issued_tag,            e[6],  TAG_W);
      chk("issue_tag",       issue_tag,             e[7],  TAG_W);
      chk("resp_retire",     resp_retire,           e[8],  1);
      chk("resp_class",      resp_class,            e[9],  3);
      chk("reclaim_req_rdy", reclaim_req_ready,     e[10], 1);
      chk("reclaim_rsp_v",   reclaim_rsp_valid,     e[11], 1);
      chk("reclaim_rsp_tag", reclaim_rsp_tag,       e[12], TAG_W);
      chk("reclaim_rsp_cls", reclaim_rsp_class,     e[13], 3);
      chk("ret_valid",       credit_return_valid,   e[14], 1);
      chk("ret_accepted",    credit_return_accepted,e[15], 1);
      chk("occupancy",       occupancy,             e[16], OCC_W);
      chk("retired_epoch",   retired_epoch,         e[17], EPOCH_W);
      for (int p=0;p<N_POOLS;p++) begin
        chk($sformatf("used[%0d]",p),      used[p*COUNT_W +: COUNT_W],      e[NSCAL+p],          COUNT_W);
        chk($sformatf("available[%0d]",p), available[p*COUNT_W +: COUNT_W], e[NSCAL+N_POOLS+p],  COUNT_W);
      end
    end
    $fclose(fd);
    if (errors==0) $display("TB_RESULT: PASS (checks=%0d)", checks);
    else           $display("TB_RESULT: FAIL (errors=%0d)", errors);
    $finish;
  end
endmodule
