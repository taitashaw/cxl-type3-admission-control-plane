// tb_credit_manager.sv — differential regression for credit_manager against the
// independent Python model (tb/models/gen_credit_vectors.py). One vector = one
// cycle: inputs driven at negedge, every output sampled and compared, the
// intervening posedge advances the ledger.
`timescale 1ns/1ps

`ifndef NPOOLS
 `define NPOOLS 2
`endif
`ifndef COUNTW
 `define COUNTW 4
`endif
`ifndef AMTW
 `define AMTW 2
`endif
`ifndef RESETMAX
 `define RESETMAX 3
`endif

module tb_credit_manager;
  localparam int unsigned N_POOLS   = `NPOOLS;
  localparam int unsigned COUNT_W   = `COUNTW;
  localparam int unsigned AMT_W     = `AMTW;
  localparam int unsigned RESET_MAX = `RESETMAX;
  localparam int unsigned PIDX_W    = (N_POOLS <= 1) ? 1 : $clog2(N_POOLS);

  logic clk = 0; always #5 clk = ~clk;
  logic rst_n;

  logic                            consume_valid, consume_ready, consume_fire;
  logic [N_POOLS-1:0][AMT_W-1:0]   consume_amount, return_amount;
  logic                            return_valid, return_accepted;
  logic [N_POOLS-1:0][COUNT_W-1:0] committed_max;
  logic                            config_commit, frozen_and_empty, diagnostic_clear;
  logic [N_POOLS-1:0][COUNT_W-1:0] used, available, configured_max, hwm_used;
  logic [N_POOLS-1:0]              pool_full, pool_empty;
  logic                            sticky_err;
  logic [2:0]                      first_err_type;
  logic [PIDX_W-1:0]               first_err_pool;
  logic [AMT_W-1:0]                first_err_amount;
  logic [31:0]                     consume_ok_count, consume_blocked_count, return_ok_count,
                                   return_illegal_count, cfg_reject_count;

  credit_manager #(.N_POOLS(N_POOLS), .COUNT_W(COUNT_W), .AMT_W(AMT_W),
                   .RESET_MAX(RESET_MAX)) dut (.*);

  integer fd, rc, count, i, p, errors, checks;
  integer f_n, f_c, f_a, f_r;
  string  vecfile;
  logic [63:0] t;

  task chk(input string nm, input int idx, input logic [63:0] got, input logic [63:0] exp, input int w);
    logic [63:0] gm, em;
    begin
      gm = got & ((w>=64)?64'hFFFFFFFFFFFFFFFF:((64'd1<<w)-1));
      em = exp & ((w>=64)?64'hFFFFFFFFFFFFFFFF:((64'd1<<w)-1));
      if (gm !== em) begin
        errors++;
        if (errors<=25) $display("   [FAIL] cyc %0d %-20s[%0d] got=%h exp=%h", i, nm, idx, gm, em);
      end
    end
  endtask

  initial begin
    if (!$value$plusargs("VEC=%s", vecfile)) begin $display("TB_RESULT: FAIL (no +VEC)"); $finish; end
    fd = $fopen(vecfile,"r");
    if (fd==0) begin $display("TB_RESULT: FAIL (open)"); $finish; end
    rc = $fscanf(fd,"%d %d %d %d %d", f_n,f_c,f_a,f_r,count);
    if (f_n!=N_POOLS||f_c!=COUNT_W||f_a!=AMT_W||f_r!=RESET_MAX) begin
      $display("TB_RESULT: FAIL (param mismatch %0d/%0d/%0d/%0d)",f_n,f_c,f_a,f_r); $finish; end
    errors=0; checks=0;
    $display("=== tb_credit_manager N_POOLS=%0d COUNT_W=%0d AMT_W=%0d RESET_MAX=%0d cycles=%0d ===",
             N_POOLS, COUNT_W, AMT_W, RESET_MAX, count);

    consume_valid=0; return_valid=0; config_commit=0; frozen_and_empty=0; diagnostic_clear=0;
    for (p=0;p<N_POOLS;p++) begin consume_amount[p]=0; return_amount[p]=0; committed_max[p]=0; end
    rst_n=0; repeat(3) @(negedge clk); rst_n=1;

    for (i=0;i<count;i++) begin
      @(negedge clk);
      // NOTE: nonblocking stimulus is REQUIRED here. Verilator's --timing
      // scheduler does not propagate procedural BLOCKING writes to individual
      // elements of a packed multidim array through a module port (Icarus does),
      // which silently feeds the DUT stale amounts. Proven by differential test.
      rc=$fscanf(fd,"%h",t); consume_valid<=t[0];
      for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); consume_amount[p]<=t[AMT_W-1:0]; end
      rc=$fscanf(fd,"%h",t); return_valid<=t[0];
      for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); return_amount[p]<=t[AMT_W-1:0]; end
      for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); committed_max[p]<=t[COUNT_W-1:0]; end
      rc=$fscanf(fd,"%h",t); config_commit<=t[0];
      rc=$fscanf(fd,"%h",t); frozen_and_empty<=t[0];
      rc=$fscanf(fd,"%h",t); diagnostic_clear<=t[0];
      #1;
      checks++;
      // vector outputs, in generator order: used, available, configured_max, hwm_used, pool_full, pool_empty
      for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); chk("used",p,used[p],t,COUNT_W); end
      for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); chk("available",p,available[p],t,COUNT_W); end
      for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); chk("configured_max",p,configured_max[p],t,COUNT_W); end
      for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); chk("hwm_used",p,hwm_used[p],t,COUNT_W); end
      for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); chk("pool_full",p,pool_full[p],t,1); end
      for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); chk("pool_empty",p,pool_empty[p],t,1); end
      // scalar outputs
      rc=$fscanf(fd,"%h",t); chk("consume_ready",0,consume_ready,t,1);
      rc=$fscanf(fd,"%h",t); chk("consume_fire",0,consume_fire,t,1);
      rc=$fscanf(fd,"%h",t); chk("return_accepted",0,return_accepted,t,1);
      rc=$fscanf(fd,"%h",t); chk("sticky_err",0,sticky_err,t,1);
      rc=$fscanf(fd,"%h",t); chk("first_err_type",0,first_err_type,t,3);
      rc=$fscanf(fd,"%h",t); chk("first_err_pool",0,first_err_pool,t,PIDX_W);
      rc=$fscanf(fd,"%h",t); chk("first_err_amount",0,first_err_amount,t,AMT_W);
      rc=$fscanf(fd,"%h",t); chk("consume_ok_count",0,consume_ok_count,t,32);
      rc=$fscanf(fd,"%h",t); chk("consume_blk_count",0,consume_blocked_count,t,32);
      rc=$fscanf(fd,"%h",t); chk("return_ok_count",0,return_ok_count,t,32);
      rc=$fscanf(fd,"%h",t); chk("return_ill_count",0,return_illegal_count,t,32);
      rc=$fscanf(fd,"%h",t); chk("cfg_reject_count",0,cfg_reject_count,t,32);
      // invariant checks at the settled sample point
      for (p=0;p<N_POOLS;p++) begin
        if (used[p] > configured_max[p]) begin errors++; $display("   [FAIL] cyc %0d INVARIANT used>max pool %0d",i,p); end
        if (available[p] !== (configured_max[p]-used[p])) begin errors++; $display("   [FAIL] cyc %0d INVARIANT avail!=max-used pool %0d",i,p); end
      end
    end
    $fclose(fd);
    $display("=== checks=%0d errors=%0d ===", checks, errors);
    $display("TB_RESULT: %s", (errors==0)?"PASS":"FAIL");
    $finish;
  end
endmodule
