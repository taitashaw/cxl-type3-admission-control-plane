// tb_mem_subsys_top.sv — differential regression for mem_subsys_top vs the model.
`timescale 1ns/1ps
`ifndef TAGW
 `define TAGW 6
`endif
`ifndef ADDRW
 `define ADDRW 2
`endif
`ifndef DATAW
 `define DATAW 8
`endif
`ifndef DEPTH
 `define DEPTH 4
`endif
`ifndef CQD
 `define CQD 4
`endif

module tb_mem_subsys_top;
  localparam int unsigned TAG_W=`TAGW, ADDR_W=`ADDRW, DATA_W=`DATAW, DEPTH=`DEPTH, CQ_DEPTH=`CQD;
  localparam int unsigned IDX_W=(DEPTH<=1)?1:$clog2(DEPTH);
  localparam int unsigned OCC_W=IDX_W+1;

  logic clk=0; always #5 clk=~clk;
  logic rst_n;
  logic iss_valid, iss_ready; logic [TAG_W-1:0] iss_tag; logic iss_write;
  logic [ADDR_W-1:0] iss_addr; logic [DATA_W-1:0] iss_wdata;
  logic rsp_valid, rsp_ready; logic [TAG_W-1:0] rsp_tag; logic [DATA_W-1:0] rsp_rdata;
  logic [OCC_W-1:0] occupancy;
  logic [DEPTH-1:0] dbg_vld, dbg_wr, dbg_issd, dbg_done;
  logic [DEPTH*ADDR_W-1:0] dbg_adr; logic [DEPTH*DATA_W-1:0] dbg_rdat;
  logic [DEPTH*DATA_W-1:0] dbg_wdat; logic [DEPTH*TAG_W-1:0] dbg_tag; logic [DEPTH*DEPTH-1:0] dbg_older;
  logic [IDX_W-1:0] dbg_alloc_slot, dbg_rsp_slot;
  logic [(1<<ADDR_W)*DATA_W-1:0] dbg_mem;
  logic dbg_mv, dbg_mr, dbg_mw; logic [ADDR_W-1:0] dbg_maddr; logic [DATA_W-1:0] dbg_mwdata;
  localparam int unsigned CPTR_W=(CQ_DEPTH<=1)?1:$clog2(CQ_DEPTH);
  localparam int unsigned CCNT_W=$clog2(CQ_DEPTH+1);
  logic [CQ_DEPTH*TAG_W-1:0] dbg_cq_tag; logic [CQ_DEPTH*DATA_W-1:0] dbg_cq_data;
  logic [CPTR_W-1:0] dbg_cq_head; logic [CCNT_W-1:0] dbg_cq_cnt;

  mem_subsys_top #(.TAG_W(TAG_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W), .DEPTH(DEPTH), .CQ_DEPTH(CQ_DEPTH)) dut (.*);

  integer fd, rc, count, i, errors, checks;
  integer h_t,h_a,h_d,h_n,h_q;
  string vecfile;
  localparam int NOUT = 5;
  logic [63:0] iv[6]; logic [63:0] e[NOUT];

  task chk(input string nm, input logic [63:0] got, input logic [63:0] exp, input int w);
    logic [63:0] gm, em;
    begin
      gm=got & ((w>=64)?64'hFFFFFFFFFFFFFFFF:((64'd1<<w)-1));
      em=exp & ((w>=64)?64'hFFFFFFFFFFFFFFFF:((64'd1<<w)-1));
      if (gm!==em) begin errors++; if (errors<=25) $display("   [FAIL] cyc %0d %-12s got=%h exp=%h", i, nm, gm, em); end
    end
  endtask

  initial begin
    if (!$value$plusargs("VEC=%s", vecfile)) begin $display("TB_RESULT: FAIL (no +VEC)"); $finish; end
    fd=$fopen(vecfile,"r"); if (fd==0) begin $display("TB_RESULT: FAIL (open)"); $finish; end
    rc=$fscanf(fd,"%d %d %d %d %d %d", h_t,h_a,h_d,h_n,h_q,count);
    if (h_t!=TAG_W||h_a!=ADDR_W||h_d!=DATA_W||h_n!=DEPTH||h_q!=CQ_DEPTH) begin $display("TB_RESULT: FAIL (param mismatch)"); $finish; end
    errors=0; checks=0;
    $display("=== tb_mem_subsys_top TAG_W=%0d ADDR_W=%0d DEPTH=%0d CQ=%0d cycles=%0d ===", TAG_W, ADDR_W, DEPTH, CQ_DEPTH, count);

    iss_valid=0; iss_tag=0; iss_write=0; iss_addr=0; iss_wdata=0; rsp_ready=0;
    rst_n=0; repeat(3) @(negedge clk); rst_n=1;
    for (i=0;i<count;i++) begin
      @(negedge clk);
      for (int j=0;j<6;j++) rc=$fscanf(fd,"%h", iv[j]);
      for (int j=0;j<NOUT;j++) rc=$fscanf(fd,"%h", e[j]);
      iss_valid=iv[0][0]; iss_tag=iv[1][TAG_W-1:0]; iss_write=iv[2][0];
      iss_addr=iv[3][ADDR_W-1:0]; iss_wdata=iv[4][DATA_W-1:0]; rsp_ready=iv[5][0];
      #1;
      checks++;
      chk("iss_ready", iss_ready, e[0], 1);
      chk("rsp_valid", rsp_valid, e[1], 1);
      chk("rsp_tag",   rsp_tag,   e[2], TAG_W);
      chk("rsp_rdata", rsp_rdata, e[3], DATA_W);
      chk("occupancy", occupancy, e[4], OCC_W);
    end
    $fclose(fd);
    if (errors==0) $display("TB_RESULT: PASS (checks=%0d)", checks);
    else           $display("TB_RESULT: FAIL (errors=%0d)", errors);
    $finish;
  end
endmodule
