// tb_system_top.sv — self-checking end-to-end scoreboard for the two-clock
// system_top (admitted request -> req CDC -> mem_subsys -> rsp CDC -> response).
// link_clk and mem_clk are INDEPENDENT free-running clocks (different periods).
// A SINGLE link-domain process (no fork -> deterministic on every simulator)
// drives admitted requests with UNIQUE outstanding tags, keeps a shadow memory
// in accept order, and checks every READ response returns the last write to its
// address accepted before it: end-to-end read-after-write ACROSS the crossing.
`timescale 1ns/1ps
`ifndef TAGW
 `define TAGW 6
`endif
`ifndef ADDRW
 `define ADDRW 3
`endif
`ifndef DATAW
 `define DATAW 8
`endif
`ifndef DEPTHP
 `define DEPTHP 4
`endif
`ifndef CQDP
 `define CQDP 4
`endif
`ifndef FAWP
 `define FAWP 2
`endif
`ifndef NTXN
 `define NTXN 4000
`endif

module tb_system_top;
  localparam int unsigned TAG_W=`TAGW, ADDR_W=`ADDRW, DATA_W=`DATAW,
                          DEPTH=`DEPTHP, CQ_DEPTH=`CQDP, FIFO_AW=`FAWP;
  localparam int unsigned IDX_W=(DEPTH<=1)?1:$clog2(DEPTH), OCC_W=IDX_W+1;
  localparam int unsigned NTAG=(1<<TAG_W);

  logic link_clk=0, mem_clk=0, link_rst_n, mem_rst_n;
  always #5 link_clk = ~link_clk;     // link period 10
  always #7 mem_clk  = ~mem_clk;      // mem period 14 (independent, coprime)

  logic iss_valid, iss_ready, iss_write; logic [TAG_W-1:0] iss_tag;
  logic [ADDR_W-1:0] iss_addr; logic [DATA_W-1:0] iss_wdata;
  logic rsp_valid, rsp_ready; logic [TAG_W-1:0] rsp_tag; logic [DATA_W-1:0] rsp_rdata;
  logic [OCC_W-1:0] occupancy;

  system_top #(.TAG_W(TAG_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W),
               .DEPTH(DEPTH), .CQ_DEPTH(CQ_DEPTH), .FIFO_AW(FIFO_AW)) dut (.*);

  // offered request (registered) drives the DUT inputs
  logic             cur_v, cur_wr;
  logic [TAG_W-1:0] cur_tag;
  logic [ADDR_W-1:0] cur_addr;
  logic [DATA_W-1:0] cur_wd;
  assign iss_valid = cur_v;
  assign iss_write = cur_wr;
  assign iss_tag   = cur_tag;
  assign iss_addr  = cur_addr;
  assign iss_wdata = cur_wd;
  assign rsp_ready = 1'b1;

  // scoreboard state
  logic [DATA_W-1:0] shadow [1<<ADDR_W];
  logic [DATA_W-1:0] exp    [NTAG];
  logic              is_rd  [NTAG];
  logic              busy   [NTAG];
  integer errors, checks, issued, idle, t, ft;
  logic [DATA_W-1:0] wcnt;

  function automatic integer free_tag();
    for (int k=0;k<NTAG;k++) if (!busy[k]) return k;
    return -1;
  endfunction
  function automatic logic some_busy();
    for (int k=0;k<NTAG;k++) if (busy[k]) return 1'b1;
    return 1'b0;
  endfunction

  initial begin
    cur_v=0; cur_wr=0; cur_tag=0; cur_addr=0; cur_wd=0;
    errors=0; checks=0; issued=0; idle=0; wcnt=1;
    for (int a=0;a<(1<<ADDR_W);a++) shadow[a]='0;
    for (int k=0;k<NTAG;k++) begin busy[k]=1'b0; is_rd[k]=1'b0; exp[k]='0; end
    link_rst_n=0; mem_rst_n=0;
    repeat(4) @(negedge link_clk); mem_rst_n=1; @(negedge link_clk); link_rst_n=1;

    forever begin
      @(posedge link_clk);
      if (link_rst_n) begin
        // 1) response checking (frees a tag)
        if (rsp_valid && rsp_ready) begin
          checks = checks + 1;
          if (busy[rsp_tag] && is_rd[rsp_tag] && (rsp_rdata !== exp[rsp_tag])) begin
            errors = errors + 1;
            if (errors<=25) $display("   [FAIL] tag=%0d read got=%h exp=%h", rsp_tag, rsp_rdata, exp[rsp_tag]);
          end
          busy[rsp_tag] = 1'b0;
        end
        // 2) accept accounting for the offered request (commit in accept order)
        if (cur_v && iss_ready) begin
          busy[cur_tag] = 1'b1;
          if (cur_wr) begin is_rd[cur_tag]=1'b0; shadow[cur_addr]=cur_wd; wcnt=wcnt+1'b1; end
          else        begin is_rd[cur_tag]=1'b1; exp[cur_tag]=shadow[cur_addr]; end
          issued = issued + 1;
          cur_v = 1'b0;
        end
        // 3) offer a fresh request if idle and tags/quota remain
        if (!cur_v && issued < `NTXN) begin
          ft = free_tag();
          if (ft >= 0) begin
            cur_v   = 1'b1;
            cur_tag = ft[TAG_W-1:0];
            cur_wr  = $urandom & 1;
            cur_addr= $urandom % (1<<ADDR_W);
            cur_wd  = wcnt;
          end
        end
        // 4) termination: every issued request produced exactly one response
        if (issued >= `NTXN && checks >= issued && !cur_v) report_and_finish();
      end
    end
  end

  task automatic report_and_finish();
    $display("=== tb_system_top TAG_W=%0d ADDR_W=%0d DEPTH=%0d CQ=%0d FAW=%0d issued=%0d resp=%0d ===",
             TAG_W, ADDR_W, DEPTH, CQ_DEPTH, FIFO_AW, issued, checks);
    if (errors==0 && checks>0) $display("TB_RESULT: PASS (checks=%0d)", checks);
    else                       $display("TB_RESULT: FAIL (errors=%0d checks=%0d)", errors, checks);
    $finish;
  endtask

  // absolute-time safety watchdog (independent of loop control)
  initial begin
    #(`NTXN * 200 + 200000);
    $display("=== tb_system_top WATCHDOG issued=%0d resp=%0d ===", issued, checks);
    $display("TB_RESULT: FAIL (watchdog: errors=%0d checks=%0d)", errors, checks);
    $finish;
  end
endmodule
