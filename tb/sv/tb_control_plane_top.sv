// tb_control_plane_top.sv — differential regression for control_plane_top vs the
// independent ControlPlane model (tb/models/gen_control_plane_vectors.py).
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
`ifndef HDMW
 `define HDMW 16
`endif
`ifndef CAPW
 `define CAPW 16
`endif

module tb_control_plane_top;
  localparam int unsigned N_POOLS=`NPOOLS, AMT_W=`AMTW, COUNT_W=`COUNTW, RESET_MAX=`RESETMAX;
  localparam int unsigned DEPTH=`DEPTH, GEN_W=`GENW, EPOCH_W=`EPOCHW, OP_W=`OPW, META_W=`METAW, TS_W=`TSW;
  localparam int unsigned HDM_W=`HDMW, CAP_W=`CAPW;
  localparam int unsigned CREDIT_VEC_W = N_POOLS*AMT_W;
  localparam int unsigned MREQ_W = COUNT_W+1;
  localparam int unsigned SLOT_W = (DEPTH<=1)?1:$clog2(DEPTH);
  localparam int unsigned TAG_W = GEN_W+SLOT_W;
  localparam int unsigned OCC_W = SLOT_W+1;

  logic clk=0; always #5 clk=~clk;
  logic rst_n;
  logic [TS_W-1:0] current_ts;
  logic cfg_req_valid, cfg_req_ready;
  logic [HDM_W-1:0] cfg_hdm_base, cfg_hdm_size; logic [CAP_W-1:0] cfg_capacity;
  logic cfg_timeout_en; logic [TS_W-1:0] cfg_timeout_thresh;
  logic [N_POOLS*MREQ_W-1:0] cfg_cmax; logic [EPOCH_W-1:0] cfg_epoch;
  logic cfg_rsp_valid, cfg_rsp_ready; logic [2:0] cfg_rsp_code, cfg_rsp_reason;
  logic req_valid; logic [OP_W-1:0] req_op; logic [META_W-1:0] req_meta;
  logic [CREDIT_VEC_W-1:0] req_credit_vec;
  logic req_ready, req_accept; logic [TAG_W-1:0] issued_tag;
  logic downstream_ready, issue_valid; logic [TAG_W-1:0] issue_tag;
  logic resp_valid; logic [TAG_W-1:0] resp_tag;
  logic resp_retire; logic [2:0] resp_class; logic [EPOCH_W-1:0] retired_epoch;
  logic reclaim_req_valid, reclaim_req_ready; logic [TAG_W-1:0] reclaim_tag;
  logic reclaim_rsp_valid, reclaim_rsp_ready; logic [TAG_W-1:0] reclaim_rsp_tag; logic [2:0] reclaim_rsp_class;
  logic global_cfg_commit_fire; logic [EPOCH_W-1:0] active_epoch;
  logic active_timeout_en; logic [TS_W-1:0] active_timeout_thresh;
  logic [HDM_W-1:0] active_hdm_base, active_hdm_size; logic [CAP_W-1:0] active_capacity;
  logic [N_POOLS*COUNT_W-1:0] used, available; logic [OCC_W-1:0] occupancy;

  control_plane_top #(.N_POOLS(N_POOLS), .AMT_W(AMT_W), .COUNT_W(COUNT_W), .RESET_MAX(RESET_MAX),
                      .DEPTH(DEPTH), .GEN_W(GEN_W), .EPOCH_W(EPOCH_W), .OP_W(OP_W),
                      .META_W(META_W), .TS_W(TS_W), .HDM_W(HDM_W), .CAP_W(CAP_W)) dut (.*);

  integer fd, rc, count, i, errors, checks;
  integer h[13];
  string vecfile;
  localparam int NSCAL = 24;
  localparam int NOUT = NSCAL + 2*N_POOLS;
  logic [63:0] iv[20];
  logic [63:0] e[NOUT];

  task chk(input string nm, input logic [63:0] got, input logic [63:0] exp, input int w);
    logic [63:0] gm, em;
    begin
      gm = got & ((w>=64)?64'hFFFFFFFFFFFFFFFF:((64'd1<<w)-1));
      em = exp & ((w>=64)?64'hFFFFFFFFFFFFFFFF:((64'd1<<w)-1));
      if (gm!==em) begin errors++; if (errors<=25) $display("   [FAIL] cyc %0d %-20s got=%h exp=%h", i, nm, gm, em); end
    end
  endtask

  initial begin
    if (!$value$plusargs("VEC=%s", vecfile)) begin $display("TB_RESULT: FAIL (no +VEC)"); $finish; end
    fd = $fopen(vecfile,"r"); if (fd==0) begin $display("TB_RESULT: FAIL (open)"); $finish; end
    rc = $fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d",
                 h[0],h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8],h[9],h[10],h[11],count);
    if (h[0]!=N_POOLS||h[1]!=AMT_W||h[2]!=COUNT_W||h[3]!=RESET_MAX||h[4]!=DEPTH||h[5]!=GEN_W
        ||h[6]!=EPOCH_W||h[7]!=OP_W||h[8]!=META_W||h[9]!=TS_W||h[10]!=HDM_W||h[11]!=CAP_W) begin
      $display("TB_RESULT: FAIL (param mismatch)"); $finish; end
    errors=0; checks=0;
    $display("=== tb_control_plane_top NP=%0d DEPTH=%0d cycles=%0d ===", N_POOLS, DEPTH, count);

    current_ts=0; cfg_req_valid=0; cfg_hdm_base=0; cfg_hdm_size=0; cfg_capacity=0;
    cfg_timeout_en=0; cfg_timeout_thresh=0; cfg_cmax=0; cfg_epoch=0; cfg_rsp_ready=0;
    req_valid=0; req_op=0; req_meta=0; req_credit_vec=0; downstream_ready=0;
    resp_valid=0; resp_tag=0; reclaim_req_valid=0; reclaim_tag=0; reclaim_rsp_ready=0;
    rst_n=0; repeat(3) @(negedge clk); rst_n=1;

    for (i=0;i<count;i++) begin
      @(negedge clk);
      for (int j=0;j<20;j++) rc=$fscanf(fd,"%h", iv[j]);
      for (int j=0;j<NOUT;j++) rc=$fscanf(fd,"%h", e[j]);
      current_ts=iv[0][TS_W-1:0]; cfg_req_valid=iv[1][0]; cfg_hdm_base=iv[2][HDM_W-1:0];
      cfg_hdm_size=iv[3][HDM_W-1:0]; cfg_capacity=iv[4][CAP_W-1:0]; cfg_timeout_en=iv[5][0];
      cfg_timeout_thresh=iv[6][TS_W-1:0]; cfg_cmax=iv[7][N_POOLS*MREQ_W-1:0]; cfg_epoch=iv[8][EPOCH_W-1:0];
      cfg_rsp_ready=iv[9][0]; req_valid=iv[10][0]; req_op=iv[11][OP_W-1:0]; req_meta=iv[12][META_W-1:0];
      req_credit_vec=iv[13][CREDIT_VEC_W-1:0]; downstream_ready=iv[14][0]; resp_valid=iv[15][0];
      resp_tag=iv[16][TAG_W-1:0]; reclaim_req_valid=iv[17][0]; reclaim_tag=iv[18][TAG_W-1:0];
      reclaim_rsp_ready=iv[19][0];
      #1;
      checks++;
      chk("cfg_req_ready",   cfg_req_ready,        e[0],  1);
      chk("cfg_rsp_valid",   cfg_rsp_valid,        e[1],  1);
      chk("cfg_rsp_code",    cfg_rsp_code,         e[2],  3);
      chk("cfg_rsp_reason",  cfg_rsp_reason,       e[3],  3);
      chk("req_ready",       req_ready,            e[4],  1);
      chk("req_accept",      req_accept,           e[5],  1);
      chk("issued_tag",      issued_tag,           e[6],  TAG_W);
      chk("issue_valid",     issue_valid,          e[7],  1);
      chk("issue_tag",       issue_tag,            e[8],  TAG_W);
      chk("resp_retire",     resp_retire,          e[9],  1);
      chk("resp_class",      resp_class,           e[10], 3);
      chk("retired_epoch",   retired_epoch,        e[11], EPOCH_W);
      chk("reclaim_req_rdy", reclaim_req_ready,    e[12], 1);
      chk("reclaim_rsp_v",   reclaim_rsp_valid,    e[13], 1);
      chk("reclaim_rsp_tag", reclaim_rsp_tag,      e[14], TAG_W);
      chk("reclaim_rsp_cls", reclaim_rsp_class,    e[15], 3);
      chk("global_commit",   global_cfg_commit_fire,e[16],1);
      chk("active_epoch",    active_epoch,         e[17], EPOCH_W);
      chk("active_to_en",    active_timeout_en,    e[18], 1);
      chk("active_to_thr",   active_timeout_thresh,e[19], TS_W);
      chk("active_hdm_base", active_hdm_base,      e[20], HDM_W);
      chk("active_hdm_size", active_hdm_size,      e[21], HDM_W);
      chk("active_capacity", active_capacity,      e[22], CAP_W);
      chk("occupancy",       occupancy,            e[23], OCC_W);
      for (int p=0;p<N_POOLS;p++) begin
        chk($sformatf("used[%0d]",p),      used[p*COUNT_W +: COUNT_W],      e[NSCAL+p],         COUNT_W);
        chk($sformatf("available[%0d]",p), available[p*COUNT_W +: COUNT_W], e[NSCAL+N_POOLS+p], COUNT_W);
      end
    end
    $fclose(fd);
    if (errors==0) $display("TB_RESULT: PASS (checks=%0d)", checks);
    else           $display("TB_RESULT: FAIL (errors=%0d)", errors);
    $finish;
  end
endmodule
