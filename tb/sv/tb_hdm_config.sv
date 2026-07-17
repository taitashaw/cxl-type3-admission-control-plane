// tb_hdm_config.sv
// Verifies hdm_config: freeze->drain->atomic-commit->reopen protocol, per-reason
// validation (differential vs the Python model's cfg_*.vec), config epoch, and
// the same-cycle-race guarantees (no new request accepted while frozen; active
// config stable while traffic outstanding; every accepted request one epoch).
`timescale 1ns/1ps

`ifndef NWIN
 `define NWIN 4
`endif
`ifndef HPAW
 `define HPAW 40
`endif
`ifndef DPAW
 `define DPAW 32
`endif

module tb_hdm_config;
  localparam int unsigned N_WIN  = `NWIN;
  localparam int unsigned HPA_W  = `HPAW;
  localparam int unsigned DPA_W  = `DPAW;
  localparam int unsigned IDX_W  = (N_WIN > 1) ? $clog2(N_WIN) : 1;
  localparam int unsigned OCNT_W = 16;

  logic clk = 0; always #5 clk = ~clk;
  logic rst_n;

  logic                    sh_we, sh_en_i, sh_cap_we, cfg_update_req;
  logic [IDX_W-1:0]        sh_idx;
  logic [HPA_W-1:0]        sh_base_i, sh_size_i;
  logic [DPA_W-1:0]        sh_dpa_i;
  logic [DPA_W:0]          sh_cap_i;
  logic [OCNT_W-1:0]       outstanding_cnt;
  logic                    traffic_freeze, req_accept_enable, cfg_update_done, cfg_ok, cfg_reject;
  logic [3:0]              cfg_reason;
  logic [15:0]             cfg_epoch;
  logic [1:0]              cfg_state;
  logic [N_WIN-1:0]              win_en;
  logic [N_WIN-1:0][HPA_W-1:0]  win_base, win_size;
  logic [N_WIN-1:0][DPA_W-1:0]  win_dpa_base;
  logic [DPA_W:0]               dev_capacity;

  hdm_config #(.HPA_W(HPA_W), .DPA_W(DPA_W), .N_WIN(N_WIN), .OCNT_W(OCNT_W)) dut (.*);

  localparam logic [3:0] CFG_OK=0;

  integer errors=0, checks=0;
  logic [15:0] exp_epoch=0;

  logic             t_en[N_WIN];
  logic [HPA_W-1:0] t_base[N_WIN], t_size[N_WIN];
  logic [DPA_W-1:0] t_dpa[N_WIN];

  task load_shadow(input logic [DPA_W:0] cap);
    int k;
    begin
      @(negedge clk); sh_we=1;
      for (k=0;k<N_WIN;k++) begin
        sh_idx=k[IDX_W-1:0]; sh_en_i=t_en[k]; sh_base_i=t_base[k]; sh_size_i=t_size[k]; sh_dpa_i=t_dpa[k];
        @(negedge clk);
      end
      sh_we=0; sh_cap_we=1; sh_cap_i=cap; @(negedge clk); sh_cap_we=0;
    end
  endtask

  // Latched verdict (cfg_ok/cfg_reject/cfg_update_done are 1-cycle pulses).
  logic       s_ok, s_reject; logic [3:0] s_reason; logic [15:0] s_epoch;

  // Pulse cfg_update_req and wait (bounded) for cfg_update_done, sampling verdict.
  task do_update;
    int guard;
    begin
      @(negedge clk); cfg_update_req=1;
      @(negedge clk); cfg_update_req=0;
      guard=0;
      while (!cfg_update_done && guard<2000) begin @(negedge clk); guard++; end
      s_ok=cfg_ok; s_reject=cfg_reject; s_reason=cfg_reason; s_epoch=cfg_epoch;
      @(negedge clk);
    end
  endtask

  // ---- differential file-driven validation --------------------------------
  integer fd, rc, count, i, k;
  integer f_n, f_h, f_d;
  string  vecfile;
  logic [63:0] u_cap,u_en,u_base,u_size,u_dpa,e_valid,e_reason;

  task run_file;
    begin
      if (!$value$plusargs("VEC=%s", vecfile)) begin
        $display("(no +VEC= given, skipping file phase)"); count=0;
      end else begin
      fd = $fopen(vecfile,"r");
      if (fd==0) begin $display("TB_RESULT: FAIL (open %s)",vecfile); $finish; end
      rc=$fscanf(fd,"%d %d %d %d", f_n,f_h,f_d,count);
      if (f_n!=N_WIN||f_h!=HPA_W||f_d!=DPA_W) begin
        $display("TB_RESULT: FAIL (param mismatch)"); $finish; end
      $display("=== tb_hdm_config file=%s vectors=%0d ===", vecfile, count);
      outstanding_cnt=0;   // file phase always drained -> valid configs commit
      for (i=0;i<count;i++) begin
        rc=$fscanf(fd,"%h",u_cap);
        for (k=0;k<N_WIN;k++) begin
          rc=$fscanf(fd,"%h %h %h %h",u_en,u_base,u_size,u_dpa);
          t_en[k]=u_en[0]; t_base[k]=u_base[HPA_W-1:0]; t_size[k]=u_size[HPA_W-1:0]; t_dpa[k]=u_dpa[DPA_W-1:0];
        end
        rc=$fscanf(fd,"%h %h", e_valid, e_reason);
        load_shadow(u_cap[DPA_W:0]);
        do_update();
        checks++;
        if (e_valid[0]) begin
          if (s_ok!==1'b1 || s_reject!==1'b0) begin
            errors++; if(errors<=20) $display("[FAIL] cfg vec %0d expected OK got ok=%b reject=%b reason=%0d",i,s_ok,s_reject,s_reason);
          end else exp_epoch++;
        end else begin
          if (s_reject!==1'b1 || s_reason!==e_reason[3:0]) begin
            errors++; if(errors<=20) $display("[FAIL] cfg vec %0d expected REJECT reason=%0d got reject=%b reason=%0d ok=%b",i,e_reason[3:0],s_reject,s_reason,s_ok);
          end
        end
        if (cfg_epoch!==exp_epoch) begin
          errors++; if(errors<=20) $display("[FAIL] cfg vec %0d epoch got=%0d exp=%0d",i,cfg_epoch,exp_epoch);
        end
      end
      $fclose(fd);
      end
    end
  endtask

  // ---- directed protocol / race tests -------------------------------------
  logic [N_WIN-1:0] active_en_snapshot;
  logic [15:0]      epoch_snapshot;

  task directed;
    int k, guard;
    begin
      for (k=0;k<N_WIN;k++) begin t_en[k]=0; t_base[k]=0; t_size[k]=0; t_dpa[k]=0; end
      t_en[0]=1; t_base[0]='h0000_1000; t_size[0]='h0001_0000; t_dpa[0]=0;

      // D1: FREEZE->DRAIN->COMMIT. Start reconfig with outstanding traffic.
      active_en_snapshot = win_en; epoch_snapshot = cfg_epoch;
      outstanding_cnt=16'd5;
      load_shadow('h40_0000);
      @(negedge clk); cfg_update_req=1; @(negedge clk); cfg_update_req=0;
      // FSM should now be FREEZE: hold here for several cycles with traffic present
      repeat (6) begin
        @(negedge clk); checks++;
        if (traffic_freeze!==1'b1 || req_accept_enable!==1'b0) begin
          errors++; $display("[FAIL] D1 not frozen: freeze=%b accept_en=%b",traffic_freeze,req_accept_enable);
        end
        // P4: active config + epoch stable while draining
        if (win_en!==active_en_snapshot || cfg_epoch!==epoch_snapshot) begin
          errors++; $display("[FAIL] D1 config changed during drain");
        end
        if (cfg_update_done!==1'b0) begin errors++; $display("[FAIL] D1 committed before drain"); end
      end
      // now drain: outstanding -> 0; FSM should commit
      outstanding_cnt=0;
      guard=0; while (!cfg_update_done && guard<50) begin @(negedge clk); guard++; end
      checks++; exp_epoch=epoch_snapshot+16'd1;
      if (cfg_ok!==1'b1 || cfg_epoch!==exp_epoch || win_en[0]!==1'b1) begin
        errors++; $display("[FAIL] D1 commit after drain: ok=%b epoch=%0d win_en=%b",cfg_ok,cfg_epoch,win_en);
      end else $display("[pass] D1 freeze->drain->commit (epoch %0d)",cfg_epoch);
      @(negedge clk);
      // req_accept_enable reopens
      checks++;
      if (req_accept_enable!==1'b1 || traffic_freeze!==1'b0) begin
        errors++; $display("[FAIL] D1 did not reopen: accept_en=%b freeze=%b",req_accept_enable,traffic_freeze);
      end else $display("[pass] D1 reopens after commit");

      // D2: invalid config is rejected immediately (no freeze, no epoch bump)
      active_en_snapshot = win_en; epoch_snapshot = cfg_epoch;
      outstanding_cnt=0;
      t_en[0]=1; t_base[0]='h0000_1020; t_size[0]='h0001_0000; t_dpa[0]=0; // unaligned base
      load_shadow('h40_0000);
      do_update();
      checks++;
      if (s_reject!==1'b1 || s_ok!==1'b0 || cfg_epoch!==epoch_snapshot || win_en!==active_en_snapshot) begin
        errors++; $display("[FAIL] D2 invalid reject: reject=%b ok=%b epoch=%0d active=%b(snap %b)",
                           s_reject,s_ok,cfg_epoch,win_en,active_en_snapshot);
      end else $display("[pass] D2 invalid config rejected immediately, active unchanged");

      // D3: same-cycle race — request accepted the cycle cfg_update_req fires must
      // see the OLD config and drain before commit. Model an in-flight request by
      // asserting outstanding_cnt=1 on the same negedge as the update request; the
      // FSM must freeze and hold commit until it drains.
      for (k=0;k<N_WIN;k++) begin t_en[k]=0; t_base[k]=0; t_size[k]=0; t_dpa[k]=0; end
      t_en[0]=1; t_base[0]='h0002_0000; t_size[0]='h0001_0000; t_dpa[0]=0;
      load_shadow('h40_0000);
      epoch_snapshot = cfg_epoch;
      @(negedge clk); cfg_update_req=1; outstanding_cnt=16'd1; // request enters same cycle
      @(negedge clk); cfg_update_req=0;
      // must NOT have committed while the in-flight request is outstanding
      repeat (4) begin
        @(negedge clk); checks++;
        if (cfg_epoch!==epoch_snapshot) begin errors++; $display("[FAIL] D3 committed while request in flight (race)"); end
        if (req_accept_enable!==1'b0) begin errors++; $display("[FAIL] D3 accepting new requests while frozen"); end
      end
      outstanding_cnt=0;   // in-flight request retires
      guard=0; while (!cfg_update_done && guard<50) begin @(negedge clk); guard++; end
      checks++;
      if (cfg_ok!==1'b1 || cfg_epoch!==epoch_snapshot+16'd1) begin
        errors++; $display("[FAIL] D3 did not commit after drain");
      end else $display("[pass] D3 no commit-vs-request race; commit only after drain (epoch %0d)",cfg_epoch);

      // D4: shadow-config TOCTOU — a shadow rewrite AFTER accept, BEFORE commit,
      // must NOT change what commits (pending snapshot is immutable).
      for (k=0;k<N_WIN;k++) begin t_en[k]=0; t_base[k]=0; t_size[k]=0; t_dpa[k]=0; end
      t_en[0]=1; t_base[0]='h0003_0000; t_size[0]='h0001_0000; t_dpa[0]=0;   // config A
      load_shadow('h40_0000);
      epoch_snapshot = cfg_epoch;
      outstanding_cnt=16'd3;
      @(negedge clk); cfg_update_req=1; @(negedge clk); cfg_update_req=0;     // accept A -> snapshot -> FREEZE
      t_en[0]=1; t_base[0]='h0005_0000; t_size[0]='h0002_0000; t_dpa[0]=0;   // config B
      load_shadow('h40_0000);                                                 // rewrite shadow while frozen
      outstanding_cnt=0;                                                      // drain
      guard=0; while (!cfg_update_done && guard<80) begin @(negedge clk); guard++; end
      checks++;
      if (cfg_ok!==1'b1 || win_base[0]!==40'h0003_0000 || win_size[0]!==40'h0001_0000) begin
        errors++; $display("[FAIL] D4 TOCTOU: committed base=%h size=%h (expected A=30000/10000)",win_base[0],win_size[0]);
      end else $display("[pass] D4 snapshot: shadow rewrite while pending did not corrupt commit");

      // D5: second cfg_update_req while an update is pending is ignored.
      for (k=0;k<N_WIN;k++) begin t_en[k]=0; t_base[k]=0; t_size[k]=0; t_dpa[k]=0; end
      t_en[0]=1; t_base[0]='h0006_0000; t_size[0]='h0001_0000; t_dpa[0]=0;
      load_shadow('h40_0000);
      outstanding_cnt=16'd2;
      @(negedge clk); cfg_update_req=1; @(negedge clk); cfg_update_req=0;     // pending (FREEZE)
      epoch_snapshot = cfg_epoch;
      @(negedge clk); cfg_update_req=1; @(negedge clk); cfg_update_req=0;     // SECOND req while pending
      @(negedge clk); checks++;
      if (traffic_freeze!==1'b1 || cfg_epoch!==epoch_snapshot || cfg_update_done!==1'b0) begin
        errors++; $display("[FAIL] D5 second update-req not ignored: freeze=%b epoch=%0d done=%b",traffic_freeze,cfg_epoch,cfg_update_done);
      end else $display("[pass] D5 second update-req while pending is ignored");
      outstanding_cnt=0;                                                      // drain the first update
      guard=0; while (!cfg_update_done && guard<50) begin @(negedge clk); guard++; end

      // D6: reset asserted mid-FREEZE recovers to ACTIVE with a disabled active
      // config and no partial commit.
      for (k=0;k<N_WIN;k++) begin t_en[k]=0; t_base[k]=0; t_size[k]=0; t_dpa[k]=0; end
      t_en[0]=1; t_base[0]='h0007_0000; t_size[0]='h0001_0000; t_dpa[0]=0;
      load_shadow('h40_0000);
      outstanding_cnt=16'd4;
      @(negedge clk); cfg_update_req=1; @(negedge clk); cfg_update_req=0;     // -> FREEZE
      @(negedge clk);                                                         // in FREEZE
      rst_n=0; repeat(2) @(negedge clk); rst_n=1; @(negedge clk);             // reset during FREEZE
      checks++;
      if (cfg_state!==2'd0 || win_en!=='0 || req_accept_enable!==1'b1 || cfg_epoch!==16'd0) begin
        errors++; $display("[FAIL] D6 reset-from-FREEZE: state=%0d win_en=%b accept=%b epoch=%0d",cfg_state,win_en,req_accept_enable,cfg_epoch);
      end else $display("[pass] D6 reset during FREEZE recovers to ACTIVE, active disabled, no partial commit");
    end
  endtask

  initial begin
    sh_we=0; sh_en_i=0; sh_base_i=0; sh_size_i=0; sh_dpa_i=0; sh_cap_we=0; sh_cap_i=0;
    cfg_update_req=0; sh_idx=0; outstanding_cnt=0;
    dut_reset;
    run_file();
    directed();
    $display("=== checks=%0d errors=%0d ===", checks, errors);
    $display("TB_RESULT: %s", (errors==0)?"PASS":"FAIL");
    $finish;
  end

  task dut_reset; begin rst_n=0; repeat(3) @(negedge clk); rst_n=1; @(negedge clk); end endtask
endmodule
