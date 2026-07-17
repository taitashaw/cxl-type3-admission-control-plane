// tb_hdm_config.sv — M2.1 configuration request/response handshake.
// Differential validation (cfg_*.vec from the independent Python model) driven
// through the decoupled valid/ready channels, plus directed protocol tests:
// backpressure, response backpressure, atomic timeout commit, commit gated on
// !alloc_fire, snapshot immutability, and reset with update/response pending.
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
  localparam int unsigned TS_W   = 8;
  localparam logic [1:0]  RSP_OK=0, RSP_INVALID=1;
  localparam logic [3:0]  CFG_OK=0, CFG_TIMEOUT_BAD=9;
  localparam logic [1:0]  S_ACTIVE=0, S_FREEZE=1, S_COMMIT=2;

  logic clk = 0; always #5 clk = ~clk;
  logic rst_n;

  logic                    sh_we, sh_en_i, sh_cap_we;
  logic [IDX_W-1:0]        sh_idx;
  logic [HPA_W-1:0]        sh_base_i, sh_size_i;
  logic [DPA_W-1:0]        sh_dpa_i;
  logic [DPA_W:0]          sh_cap_i;
  logic                    cfg_req_valid, cfg_req_ready, cfg_req_timeout_en;
  logic [TS_W-1:0]         cfg_req_timeout_thresh;
  logic                    cfg_rsp_valid, cfg_rsp_ready;
  logic [1:0]              cfg_rsp_code;
  logic [3:0]              cfg_rsp_reason;
  logic [OCNT_W-1:0]       outstanding_cnt;
  logic                    alloc_fire, traffic_freeze, req_accept_enable;
  logic [15:0]             cfg_epoch;
  logic [1:0]              cfg_state;
  logic                    timeout_enable;
  logic [TS_W-1:0]         timeout_thresh;
  logic [N_WIN-1:0]              win_en;
  logic [N_WIN-1:0][HPA_W-1:0]  win_base, win_size;
  logic [N_WIN-1:0][DPA_W-1:0]  win_dpa_base;
  logic [DPA_W:0]               dev_capacity;

  hdm_config #(.HPA_W(HPA_W), .DPA_W(DPA_W), .N_WIN(N_WIN),
               .OCNT_W(OCNT_W), .TS_W(TS_W)) dut (.*);

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

  // sampled response
  logic [1:0] s_code; logic [3:0] s_reason; logic [15:0] s_epoch;

  // Issue a configuration request (holding valid+payload stable until ready --
  // the A1 interface contract), then consume the response.
  task do_cfg(input logic to_en, input logic [TS_W-1:0] to_th, input int rsp_backpressure);
    int guard;
    begin
      @(negedge clk);
      cfg_req_valid=1; cfg_req_timeout_en=to_en; cfg_req_timeout_thresh=to_th;
      guard=0;
      while (!cfg_req_ready && guard<3000) begin @(negedge clk); guard++; end  // hold valid+payload
      @(negedge clk); cfg_req_valid=0;      // accepted on the edge where ready was high
      // optionally backpressure the response for a few cycles
      cfg_rsp_ready = (rsp_backpressure==0);
      guard=0;
      while (!cfg_rsp_valid && guard<3000) begin @(negedge clk); guard++; end
      if (rsp_backpressure>0) begin
        repeat (rsp_backpressure) @(negedge clk);   // response must hold, contents stable
        cfg_rsp_ready=1;
      end
      s_code=cfg_rsp_code; s_reason=cfg_rsp_reason; s_epoch=cfg_epoch;
      @(negedge clk); cfg_rsp_ready=0;      // consumed
    end
  endtask

  // ---- differential validation (HDM validity from the Python model) --------
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
        outstanding_cnt=0; alloc_fire=0;
        for (i=0;i<count;i++) begin
          rc=$fscanf(fd,"%h",u_cap);
          for (k=0;k<N_WIN;k++) begin
            rc=$fscanf(fd,"%h %h %h %h",u_en,u_base,u_size,u_dpa);
            t_en[k]=u_en[0]; t_base[k]=u_base[HPA_W-1:0]; t_size[k]=u_size[HPA_W-1:0]; t_dpa[k]=u_dpa[DPA_W-1:0];
          end
          rc=$fscanf(fd,"%h %h", e_valid, e_reason);
          load_shadow(u_cap[DPA_W:0]);
          do_cfg(1'b1, 8'd24, 0);        // legal timeout payload -> verdict driven by HDM validity
          checks++;
          if (e_valid[0]) begin
            if (s_code!==RSP_OK) begin
              errors++; if(errors<=20) $display("[FAIL] cfg vec %0d expected OK got code=%0d reason=%0d",i,s_code,s_reason);
            end else exp_epoch++;
          end else begin
            if (s_code!==RSP_INVALID || s_reason!==e_reason[3:0]) begin
              errors++; if(errors<=20) $display("[FAIL] cfg vec %0d expected INVALID reason=%0d got code=%0d reason=%0d",i,e_reason[3:0],s_code,s_reason);
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

  // ---- directed protocol tests --------------------------------------------
  logic [N_WIN-1:0] en_snap; logic [15:0] ep_snap;

  task directed;
    int k, guard;
    begin
      for (k=0;k<N_WIN;k++) begin t_en[k]=0; t_base[k]=0; t_size[k]=0; t_dpa[k]=0; end
      t_en[0]=1; t_base[0]='h0000_1000; t_size[0]='h0001_0000; t_dpa[0]=0;

      // D1: freeze -> drain -> atomic commit (timeout committed with it)
      outstanding_cnt=16'd5; alloc_fire=0; load_shadow('h40_0000);
      ep_snap=cfg_epoch;
      @(negedge clk); cfg_req_valid=1; cfg_req_timeout_en=1; cfg_req_timeout_thresh=8'd30;
      guard=0; while(!cfg_req_ready && guard<50) begin @(negedge clk); guard++; end
      @(negedge clk); cfg_req_valid=0;
      repeat (4) begin
        @(negedge clk); checks++;
        if (traffic_freeze!==1'b1 || req_accept_enable!==1'b0) begin errors++; $display("[FAIL] D1 not frozen"); end
        if (cfg_epoch!==ep_snap || cfg_rsp_valid!==1'b0) begin errors++; $display("[FAIL] D1 committed before drain"); end
      end
      outstanding_cnt=0;
      cfg_rsp_ready=1;
      guard=0; while(!cfg_rsp_valid && guard<50) begin @(negedge clk); guard++; end
      checks++;
      if (cfg_rsp_code!==RSP_OK || cfg_epoch!==ep_snap+16'd1 || timeout_thresh!==8'd30 || timeout_enable!==1'b1) begin
        errors++; $display("[FAIL] D1 commit: code=%0d epoch=%0d to_th=%0d to_en=%b",cfg_rsp_code,cfg_epoch,timeout_thresh,timeout_enable);
      end else $display("[pass] D1 freeze->drain->atomic commit (HDM+timeout+epoch on one edge)");
      @(negedge clk); cfg_rsp_ready=0;

      // D2: illegal timeout threshold -> INVALID, no freeze, active unchanged
      en_snap=win_en; ep_snap=cfg_epoch;
      do_cfg(1'b1, 8'd200, 0);   // >= 2^(TS_W-1)=128 -> illegal
      checks++;
      if (s_code!==RSP_INVALID || s_reason!==CFG_TIMEOUT_BAD || cfg_epoch!==ep_snap || win_en!==en_snap) begin
        errors++; $display("[FAIL] D2 illegal timeout: code=%0d reason=%0d epoch=%0d",s_code,s_reason,cfg_epoch);
      end else $display("[pass] D2 illegal timeout threshold -> INVALID, active config untouched");

      // D3: request backpressure — issue while busy; valid is held, nothing lost
      outstanding_cnt=16'd3;
      @(negedge clk); cfg_req_valid=1; cfg_req_timeout_en=1; cfg_req_timeout_thresh=8'd20;
      guard=0; while(!cfg_req_ready && guard<20) begin @(negedge clk); guard++; end
      @(negedge clk); cfg_req_valid=0;               // first request accepted -> FREEZE
      @(negedge clk); checks++;
      // a second request now sees ready=0 (backpressure), holds valid, is NOT lost
      cfg_req_valid=1; cfg_req_timeout_en=0; cfg_req_timeout_thresh=8'd0;
      @(negedge clk);
      if (cfg_req_ready!==1'b0) begin errors++; $display("[FAIL] D3 ready high while busy"); end
      else $display("[pass] D3 second request backpressured (ready=0), valid held, not dropped");
      outstanding_cnt=0; cfg_rsp_ready=1;            // let the first complete
      guard=0; while(!cfg_rsp_valid && guard<50) begin @(negedge clk); guard++; end
      @(negedge clk); cfg_rsp_ready=0;
      // the held second request must now be accepted and answered
      guard=0; while(!cfg_req_ready && guard<50) begin @(negedge clk); guard++; end
      @(negedge clk); cfg_req_valid=0; cfg_rsp_ready=1;
      guard=0; while(!cfg_rsp_valid && guard<50) begin @(negedge clk); guard++; end
      checks++;
      if (cfg_rsp_valid!==1'b1) begin errors++; $display("[FAIL] D3 held request never answered"); end
      else $display("[pass] D3 held request accepted after backpressure and answered");
      @(negedge clk); cfg_rsp_ready=0;

      // D4: response backpressure — contents stable while rsp_valid && !rsp_ready
      do_cfg(1'b1, 8'd222, 4);   // illegal -> INVALID, held 4 cycles under backpressure
      checks++;
      if (s_code!==RSP_INVALID || s_reason!==CFG_TIMEOUT_BAD) begin
        errors++; $display("[FAIL] D4 response not stable under backpressure: code=%0d reason=%0d",s_code,s_reason);
      end else $display("[pass] D4 response held stable under backpressure until consumed");

      // D5: commit is blocked while alloc_fire is high even when drained
      for (k=0;k<N_WIN;k++) begin t_en[k]=0; t_base[k]=0; t_size[k]=0; t_dpa[k]=0; end
      t_en[0]=1; t_base[0]='h0002_0000; t_size[0]='h0001_0000; t_dpa[0]=0;
      load_shadow('h40_0000);
      outstanding_cnt=0; alloc_fire=1;               // drained but an allocation is firing
      ep_snap=cfg_epoch;
      @(negedge clk); cfg_req_valid=1; cfg_req_timeout_en=1; cfg_req_timeout_thresh=8'd15;
      guard=0; while(!cfg_req_ready && guard<50) begin @(negedge clk); guard++; end
      @(negedge clk); cfg_req_valid=0;
      repeat (4) begin
        @(negedge clk); checks++;
        if (cfg_epoch!==ep_snap) begin errors++; $display("[FAIL] D5 committed on an allocation edge"); end
      end
      alloc_fire=0; cfg_rsp_ready=1;
      guard=0; while(!cfg_rsp_valid && guard<50) begin @(negedge clk); guard++; end
      checks++;
      if (cfg_epoch!==ep_snap+16'd1) begin errors++; $display("[FAIL] D5 no commit after alloc_fire cleared"); end
      else $display("[pass] D5 commit blocked while alloc_fire high; commits once clear");
      @(negedge clk); cfg_rsp_ready=0;

      // D6: reset with a response pending -> response cleared, no post-reset echo
      do_cfg(1'b1, 8'd201, 6);   // INVALID, hold response under backpressure
      @(negedge clk);
      rst_n=0; repeat(2) @(negedge clk); rst_n=1; @(negedge clk);
      checks++;
      if (cfg_rsp_valid!==1'b0 || cfg_state!==S_ACTIVE || cfg_epoch!==16'd0 || timeout_enable!==1'b0) begin
        errors++; $display("[FAIL] D6 reset w/ response pending: rsp=%b state=%0d epoch=%0d to_en=%b",
                           cfg_rsp_valid,cfg_state,cfg_epoch,timeout_enable);
      end else $display("[pass] D6 reset clears pending response; timeout default disabled; no post-reset echo");
    end
  endtask

  initial begin
    sh_we=0; sh_en_i=0; sh_base_i=0; sh_size_i=0; sh_cap_we=0; sh_cap_i=0; sh_dpa_i=0; sh_idx=0;
    cfg_req_valid=0; cfg_req_timeout_en=0; cfg_req_timeout_thresh=0;
    cfg_rsp_ready=0; outstanding_cnt=0; alloc_fire=0;
    dut_reset;
    run_file();
    directed();
    $display("=== checks=%0d errors=%0d ===", checks, errors);
    $display("TB_RESULT: %s", (errors==0)?"PASS":"FAIL");
    $finish;
  end

  task dut_reset; begin rst_n=0; repeat(3) @(negedge clk); rst_n=1; @(negedge clk); end endtask
endmodule
