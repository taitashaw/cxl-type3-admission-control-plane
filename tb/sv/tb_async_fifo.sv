// tb_async_fifo.sv — event-driven two-clock differential for async_fifo vs the
// independent Python model. Each vector line is ONE clock edge in one domain
// (ev=0 write-domain, ev=1 read-domain); the TB pulses that domain's clock and
// compares full/empty/rd_data against the model's expected values.
`timescale 1ns/1ps
`ifndef WIDTHP
 `define WIDTHP 4
`endif
`ifndef ADDRWP
 `define ADDRWP 2
`endif

module tb_async_fifo;
  localparam int unsigned WIDTH = `WIDTHP, ADDR_W = `ADDRWP;

  logic wr_clk=0, rd_clk=0, wr_rst_n, rd_rst_n;
  logic wr_en; logic [WIDTH-1:0] wr_data; logic full;
  logic rd_en; logic [WIDTH-1:0] rd_data; logic empty;
  logic [ADDR_W:0] dbg_wbin,dbg_wgray,dbg_rbin,dbg_rgray,dbg_wgray_s,dbg_rgray_s,dbg_wgray_s0,dbg_rgray_s0;
  logic [(1<<ADDR_W)*WIDTH-1:0] dbg_mem;

  async_fifo #(.WIDTH(WIDTH), .ADDR_W(ADDR_W)) dut (.*);

  integer fd, rc, count, i, errors, checks;
  integer h_w, h_a;
  string vecfile;
  logic [63:0] ev, ie_wr, iv_wd, ie_rd, e_full, e_empty, e_rd;

  task automatic wr_tick; begin #1 wr_clk=1; #1 wr_clk=0; #1; end endtask
  task automatic rd_tick; begin #1 rd_clk=1; #1 rd_clk=0; #1; end endtask

  task chk(input string nm, input logic [63:0] got, input logic [63:0] exp, input int w);
    logic [63:0] gm, em;
    begin
      gm = got & ((64'd1<<w)-1); em = exp & ((64'd1<<w)-1);
      if (gm!==em) begin errors++; if (errors<=25) $display("   [FAIL] ev %0d %-8s got=%h exp=%h", i, nm, gm, em); end
    end
  endtask

  initial begin
    if (!$value$plusargs("VEC=%s", vecfile)) begin $display("TB_RESULT: FAIL (no +VEC)"); $finish; end
    fd=$fopen(vecfile,"r"); if (fd==0) begin $display("TB_RESULT: FAIL (open)"); $finish; end
    rc=$fscanf(fd,"%d %d %d", h_w, h_a, count);
    if (h_w!=WIDTH || h_a!=ADDR_W) begin $display("TB_RESULT: FAIL (param mismatch)"); $finish; end
    errors=0; checks=0;
    $display("=== tb_async_fifo WIDTH=%0d ADDR_W=%0d events=%0d ===", WIDTH, ADDR_W, count);

    // reset both domains (async assert, release)
    wr_en=0; wr_data=0; rd_en=0; wr_rst_n=0; rd_rst_n=0;
    wr_tick; rd_tick; wr_rst_n=1; rd_rst_n=1; wr_tick; rd_tick;

    for (i=0;i<count;i++) begin
      rc=$fscanf(fd,"%h %h %h %h %h %h %h", ev, ie_wr, iv_wd, ie_rd, e_full, e_empty, e_rd);
      wr_en=ie_wr[0]; wr_data=iv_wd[WIDTH-1:0]; rd_en=ie_rd[0];
      if (ev[0]==1'b0) wr_tick; else rd_tick;
      #1;
      checks++;
      chk("full",    full,    e_full,  1);
      chk("empty",   empty,   e_empty, 1);
      if (e_empty==0) chk("rd_data", rd_data, e_rd, WIDTH);   // rd_data is don't-care when empty
    end
    $fclose(fd);
    if (errors==0) $display("TB_RESULT: PASS (checks=%0d)", checks);
    else           $display("TB_RESULT: FAIL (errors=%0d)", errors);
    $finish;
  end
endmodule
