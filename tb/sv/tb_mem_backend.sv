// tb_mem_backend.sv — differential regression for mem_backend vs the Python model.
`timescale 1ns/1ps
`ifndef TAGW
 `define TAGW 6
`endif
`ifndef ADDRW
 `define ADDRW 4
`endif
`ifndef DATAW
 `define DATAW 8
`endif
`ifndef CQD
 `define CQD 4
`endif

module tb_mem_backend;
  localparam int unsigned TAG_W=`TAGW, ADDR_W=`ADDRW, DATA_W=`DATAW, CQ_DEPTH=`CQD;
  logic clk=0; always #5 clk=~clk;
  logic rst_n;
  logic req_valid, req_ready; logic [TAG_W-1:0] req_tag; logic req_write;
  logic [ADDR_W-1:0] req_addr; logic [DATA_W-1:0] req_wdata;
  logic cmp_valid, cmp_ready; logic [TAG_W-1:0] cmp_tag; logic [DATA_W-1:0] cmp_rdata;
  logic [(1<<ADDR_W)*DATA_W-1:0] dbg_mem;
  localparam int unsigned CPTR_W=(CQ_DEPTH<=1)?1:$clog2(CQ_DEPTH);
  localparam int unsigned CCNT_W=$clog2(CQ_DEPTH+1);
  logic [CQ_DEPTH*TAG_W-1:0] dbg_cq_tag; logic [CQ_DEPTH*DATA_W-1:0] dbg_cq_data;
  logic [CPTR_W-1:0] dbg_cq_head; logic [CCNT_W-1:0] dbg_cq_cnt;

  mem_backend #(.TAG_W(TAG_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W), .CQ_DEPTH(CQ_DEPTH)) dut (.*);

  integer fd, rc, count, i, errors, checks;
  integer h_t,h_a,h_d,h_q;
  string vecfile;
  localparam int NOUT = 4;
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
    rc=$fscanf(fd,"%d %d %d %d %d", h_t,h_a,h_d,h_q,count);
    if (h_t!=TAG_W||h_a!=ADDR_W||h_d!=DATA_W||h_q!=CQ_DEPTH) begin $display("TB_RESULT: FAIL (param mismatch)"); $finish; end
    errors=0; checks=0;
    $display("=== tb_mem_backend TAG_W=%0d ADDR_W=%0d CQ=%0d cycles=%0d ===", TAG_W, ADDR_W, CQ_DEPTH, count);

    req_valid=0; req_tag=0; req_write=0; req_addr=0; req_wdata=0; cmp_ready=0;
    rst_n=0; repeat(3) @(negedge clk); rst_n=1;
    for (i=0;i<count;i++) begin
      @(negedge clk);
      for (int j=0;j<6;j++) rc=$fscanf(fd,"%h", iv[j]);
      for (int j=0;j<NOUT;j++) rc=$fscanf(fd,"%h", e[j]);
      req_valid=iv[0][0]; req_tag=iv[1][TAG_W-1:0]; req_write=iv[2][0];
      req_addr=iv[3][ADDR_W-1:0]; req_wdata=iv[4][DATA_W-1:0]; cmp_ready=iv[5][0];
      #1;
      checks++;
      chk("req_ready", req_ready, e[0], 1);
      chk("cmp_valid", cmp_valid, e[1], 1);
      chk("cmp_tag",   cmp_tag,   e[2], TAG_W);
      chk("cmp_rdata", cmp_rdata, e[3], DATA_W);
    end
    $fclose(fd);
    if (errors==0) $display("TB_RESULT: PASS (checks=%0d)", checks);
    else           $display("TB_RESULT: FAIL (errors=%0d)", errors);
    $finish;
  end
endmodule
