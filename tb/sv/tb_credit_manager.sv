// tb_credit_manager.sv — differential regression for credit_manager vs the
// independent Python model (tb/models/gen_credit_vectors.py).
//
// STIMULUS: the DUT ports are FLAT ([N*W-1:0]); every input is composed in a
// local temp via shift/OR (whole-variable writes only) and driven with ONE
// whole-vector assignment per cycle. No packed-multidim element writes exist, so
// no engine can silently feed the DUT stale values.
//
// A walking-one PORT-MAPPING test runs first: for each pool p it issues an
// illegal return of amount 1 on pool p ALONE (after reset used[]==0) and checks
// the DUT reports first_err_pool==p, first_err_amount==1, ledger unchanged. This
// distinguishes a TB flat<->slice MAPPING fault from a DUT INDEXING fault before
// any differential vectors run (both use the identical p*W +: W convention).
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
`ifndef DIAGW
 `define DIAGW 32
`endif

module tb_credit_manager;
  localparam int unsigned N_POOLS   = `NPOOLS;
  localparam int unsigned COUNT_W   = `COUNTW;
  localparam int unsigned AMT_W     = `AMTW;
  localparam int unsigned RESET_MAX = `RESETMAX;
  localparam int unsigned DIAG_W    = `DIAGW;
  localparam int unsigned PIDX_W    = (N_POOLS <= 1) ? 1 : $clog2(N_POOLS);
  localparam int unsigned MREQ_W    = COUNT_W + 1;
  localparam int unsigned AFLAT     = N_POOLS*AMT_W;
  localparam int unsigned CFLAT     = N_POOLS*COUNT_W;
  localparam int unsigned MFLAT     = N_POOLS*MREQ_W;

  logic clk = 0; always #5 clk = ~clk;
  logic rst_n;

  logic                consume_valid, return_valid, config_commit, frozen_and_empty, diagnostic_clear;
  logic [AFLAT-1:0]    consume_amount, return_amount;
  logic [MFLAT-1:0]    committed_max;
  logic                consume_ready, consume_fire, return_accepted, cfg_commit_fire, cfg_reject;
  logic [2:0]          cfg_reason;
  logic [CFLAT-1:0]    used, available, configured_max, hwm_used;
  logic [N_POOLS-1:0]  pool_full, pool_empty;
  logic                sticky_err;
  logic [2:0]          first_err_type;
  logic [PIDX_W-1:0]   first_err_pool;
  logic [AMT_W-1:0]    first_err_amount;
  logic [DIAG_W-1:0]   consume_ok_count, consume_blocked_count, return_ok_count,
                       return_illegal_count, cfg_reject_count;

  credit_manager #(.N_POOLS(N_POOLS), .COUNT_W(COUNT_W), .AMT_W(AMT_W),
                   .RESET_MAX(RESET_MAX), .DIAG_W(DIAG_W)) dut (.*);

  // read-only slice views
  function automatic logic [COUNT_W-1:0] cs(input logic [CFLAT-1:0] v, input int p);
    cs = v[p*COUNT_W +: COUNT_W];
  endfunction

  integer fd, rc, count, i, p, errors, checks;
  integer f_n, f_c, f_a, f_r, f_d;
  string  vecfile;
  logic [63:0] t;
  logic [AFLAT-1:0] a1, a2;
  logic [MFLAT-1:0] mf;

  task chk(input string nm, input int idx, input logic [63:0] got, input logic [63:0] exp, input int w);
    logic [63:0] gm, em;
    begin
      gm = got & ((w>=64)?64'hFFFFFFFFFFFFFFFF:((64'd1<<w)-1));
      em = exp & ((w>=64)?64'hFFFFFFFFFFFFFFFF:((64'd1<<w)-1));
      if (gm !== em) begin
        errors++;
        if (errors<=25) $display("   [FAIL] cyc %0d %-18s[%0d] got=%h exp=%h", i, nm, idx, gm, em);
      end
    end
  endtask

  task do_reset;
    begin
      consume_valid<=0; return_valid<=0; config_commit<=0; frozen_and_empty<=0; diagnostic_clear<=0;
      consume_amount<='0; return_amount<='0; committed_max<='0;
      rst_n=0; repeat(3) @(negedge clk); rst_n=1; @(negedge clk);
    end
  endtask

  // ---- WALKING-ONE PORT-MAPPING TEST ---------------------------------------
  integer map_err;
  task walking_one_map_test;
    begin
      map_err = 0;
      $display("=== walking-one port-mapping test (N_POOLS=%0d) ===", N_POOLS);
      for (p=0; p<N_POOLS; p++) begin
        do_reset();
        a1 = '0; a1[p*AMT_W +: AMT_W] = AMT_W'(1);   // walking one: return amount 1, pool p only
        @(negedge clk);
        return_amount <= a1; return_valid <= 1'b1; consume_amount <= '0; consume_valid <= 1'b0;
        @(negedge clk); #1;
        if (return_accepted !== 1'b0) begin map_err++; $display("   [MAP-FAIL] pool %0d illegal return ACCEPTED", p); end
        @(negedge clk); #1;   // registered snapshot lands
        if (first_err_pool !== p[PIDX_W-1:0] || first_err_amount !== AMT_W'(1) || first_err_type !== 3'd1) begin
          map_err++;
          $display("   [MAP-FAIL] pool %0d: err_pool=%0d err_amt=%0d err_type=%0d (expect %0d/1/1)",
                   p, first_err_pool, first_err_amount, first_err_type, p);
        end
        for (int q=0;q<N_POOLS;q++)
          if (cs(used,q) !== '0) begin map_err++; $display("   [MAP-FAIL] pool %0d ledger changed used[%0d]=%0d",p,q,cs(used,q)); end
        return_valid <= 1'b0;
      end
      if (map_err==0) $display("   [pass] port mapping verified (flat<->slice and DUT indexing agree)");
      else            $display("   PORT-MAPPING TEST FAILED (%0d errors) -> TB mapping or DUT indexing bug", map_err);
      errors += map_err;
    end
  endtask

  initial begin
    if (!$value$plusargs("VEC=%s", vecfile)) begin $display("TB_RESULT: FAIL (no +VEC)"); $finish; end
    fd = $fopen(vecfile,"r");
    if (fd==0) begin $display("TB_RESULT: FAIL (open)"); $finish; end
    rc = $fscanf(fd,"%d %d %d %d %d %d", f_n,f_c,f_a,f_r,f_d,count);
    if (f_n!=N_POOLS||f_c!=COUNT_W||f_a!=AMT_W||f_r!=RESET_MAX||f_d!=DIAG_W) begin
      $display("TB_RESULT: FAIL (param mismatch %0d/%0d/%0d/%0d/%0d)",f_n,f_c,f_a,f_r,f_d); $finish; end
    errors=0; checks=0;
    $display("=== tb_credit_manager N_POOLS=%0d COUNT_W=%0d AMT_W=%0d RESET_MAX=%0d cycles=%0d ===",
             N_POOLS, COUNT_W, AMT_W, RESET_MAX, count);

    do_reset();
    walking_one_map_test();
    do_reset();

    for (i=0;i<count;i++) begin
      @(negedge clk);
      rc=$fscanf(fd,"%h",t); consume_valid <= t[0];
      a1='0; for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); a1[p*AMT_W +: AMT_W] = t[AMT_W-1:0]; end
      consume_amount <= a1;
      rc=$fscanf(fd,"%h",t); return_valid <= t[0];
      a2='0; for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); a2[p*AMT_W +: AMT_W] = t[AMT_W-1:0]; end
      return_amount <= a2;
      mf='0; for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); mf[p*MREQ_W +: MREQ_W] = t[MREQ_W-1:0]; end
      committed_max <= mf;
      rc=$fscanf(fd,"%h",t); config_commit    <= t[0];
      rc=$fscanf(fd,"%h",t); frozen_and_empty <= t[0];
      rc=$fscanf(fd,"%h",t); diagnostic_clear <= t[0];
      #1;
      checks++;
      for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); chk("used",p,cs(used,p),t,COUNT_W); end
      for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); chk("available",p,cs(available,p),t,COUNT_W); end
      for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); chk("configured_max",p,cs(configured_max,p),t,COUNT_W); end
      for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); chk("hwm_used",p,cs(hwm_used,p),t,COUNT_W); end
      for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); chk("pool_full",p,pool_full[p],t,1); end
      for (p=0;p<N_POOLS;p++) begin rc=$fscanf(fd,"%h",t); chk("pool_empty",p,pool_empty[p],t,1); end
      rc=$fscanf(fd,"%h",t); chk("consume_ready",0,consume_ready,t,1);
      rc=$fscanf(fd,"%h",t); chk("consume_fire",0,consume_fire,t,1);
      rc=$fscanf(fd,"%h",t); chk("return_accepted",0,return_accepted,t,1);
      rc=$fscanf(fd,"%h",t); chk("cfg_commit_fire",0,cfg_commit_fire,t,1);
      rc=$fscanf(fd,"%h",t); chk("cfg_reject",0,cfg_reject,t,1);
      rc=$fscanf(fd,"%h",t); chk("cfg_reason",0,cfg_reason,t,3);
      rc=$fscanf(fd,"%h",t); chk("sticky_err",0,sticky_err,t,1);
      rc=$fscanf(fd,"%h",t); chk("first_err_type",0,first_err_type,t,3);
      rc=$fscanf(fd,"%h",t); chk("first_err_pool",0,first_err_pool,t,PIDX_W);
      rc=$fscanf(fd,"%h",t); chk("first_err_amount",0,first_err_amount,t,AMT_W);
      rc=$fscanf(fd,"%h",t); chk("consume_ok_count",0,consume_ok_count,t,DIAG_W);
      rc=$fscanf(fd,"%h",t); chk("consume_blk_count",0,consume_blocked_count,t,DIAG_W);
      rc=$fscanf(fd,"%h",t); chk("return_ok_count",0,return_ok_count,t,DIAG_W);
      rc=$fscanf(fd,"%h",t); chk("return_ill_count",0,return_illegal_count,t,DIAG_W);
      rc=$fscanf(fd,"%h",t); chk("cfg_reject_count",0,cfg_reject_count,t,DIAG_W);
      for (p=0;p<N_POOLS;p++) begin
        if (cs(used,p) > cs(configured_max,p)) begin errors++; $display("   [FAIL] cyc %0d INVARIANT used>max pool %0d",i,p); end
        if (cs(available,p) !== (cs(configured_max,p)-cs(used,p))) begin errors++; $display("   [FAIL] cyc %0d INVARIANT avail!=max-used pool %0d",i,p); end
      end
    end
    $fclose(fd);
    $display("=== checks=%0d errors=%0d ===", checks, errors);
    $display("TB_RESULT: %s", (errors==0)?"PASS":"FAIL");
    $finish;
  end
endmodule
