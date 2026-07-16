// tb_hdm_config.sv
// Verifies hdm_config: shadow->validate->atomic-commit protocol, per-reason
// validation (differential vs the Python model's cfg_*.vec), config epoch,
// the outstanding/drain gate, and atomicity of rejected commits.
`timescale 1ns/1ps
`include "cxl_types_pkg.sv"

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

  logic                    sh_we, sh_en_i, sh_cap_we, commit;
  logic [IDX_W-1:0]        sh_idx;
  logic [HPA_W-1:0]        sh_base_i, sh_size_i;
  logic [DPA_W-1:0]        sh_dpa_i;
  logic [DPA_W:0]          sh_cap_i;
  logic [OCNT_W-1:0]       outstanding_cnt;
  logic                    cfg_committed, cfg_reject;
  logic [3:0]              cfg_reason;
  logic [15:0]             cfg_epoch;
  logic [N_WIN-1:0]              win_en;
  logic [N_WIN-1:0][HPA_W-1:0]  win_base, win_size;
  logic [N_WIN-1:0][DPA_W-1:0]  win_dpa_base;
  logic [DPA_W:0]               dev_capacity;

  hdm_config #(.HPA_W(HPA_W), .DPA_W(DPA_W), .N_WIN(N_WIN), .OCNT_W(OCNT_W)) dut (.*);

  localparam logic [3:0] CFG_OK=0, CFG_BUSY=9;

  integer errors=0, checks=0;
  logic [15:0] exp_epoch=0;

  // module-level shadow temps (Icarus rejects unpacked-array task ports, so the
  // load task reads these directly rather than taking array arguments)
  logic             t_en[N_WIN];
  logic [HPA_W-1:0] t_base[N_WIN], t_size[N_WIN];
  logic [DPA_W-1:0] t_dpa[N_WIN];

  // Load the current t_* temps into shadow (one window per cycle), then cap.
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

  // Latched verdict (cfg_committed/cfg_reject/cfg_reason are 1-cycle pulses).
  logic       s_committed, s_reject;
  logic [3:0] s_reason;
  logic [15:0] s_epoch;

  // Pulse commit for one cycle and SAMPLE the verdict at the capturing edge.
  task do_commit;
    begin
      commit=1;
      @(negedge clk);                 // the posedge just before this captured commit
      s_committed = cfg_committed;     // pulses are valid right now
      s_reject    = cfg_reject;
      s_reason    = cfg_reason;
      s_epoch     = cfg_epoch;
      commit=0;
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
      for (i=0;i<count;i++) begin
        rc=$fscanf(fd,"%h",u_cap);
        for (k=0;k<N_WIN;k++) begin
          rc=$fscanf(fd,"%h %h %h %h",u_en,u_base,u_size,u_dpa);
          t_en[k]=u_en[0]; t_base[k]=u_base[HPA_W-1:0]; t_size[k]=u_size[HPA_W-1:0]; t_dpa[k]=u_dpa[DPA_W-1:0];
        end
        rc=$fscanf(fd,"%h %h", e_valid, e_reason);
        outstanding_cnt=0;
        load_shadow(u_cap[DPA_W:0]);
        do_commit();
        checks++;
        if (e_valid[0]) begin
          if (s_committed!==1'b1 || s_reject!==1'b0) begin
            errors++; if(errors<=20) $display("[FAIL] cfg vec %0d expected COMMIT got committed=%b reject=%b reason=%0d",i,s_committed,s_reject,s_reason);
          end else exp_epoch++;
        end else begin
          if (s_reject!==1'b1 || s_reason!==e_reason[3:0]) begin
            errors++; if(errors<=20) $display("[FAIL] cfg vec %0d expected REJECT reason=%0d got reject=%b reason=%0d committed=%b",i,e_reason[3:0],s_reject,s_reason,s_committed);
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
  logic [N_WIN-1:0] active_en_snapshot;

  task directed;
    int k;
    begin
      // a clean valid window-0-only config using small, width-safe constants
      // (fits every sweep config incl. N_WIN=1, HPA_W=32, DPA_W=24).
      for (k=0;k<N_WIN;k++) begin t_en[k]=0; t_base[k]=0; t_size[k]=0; t_dpa[k]=0; end
      t_en[0]=1; t_base[0]='h0000_1000; t_size[0]='h0001_0000; t_dpa[0]=0;

      // D1: drain gate — commit while outstanding!=0 must reject with BUSY, no epoch bump, active untouched
      active_en_snapshot = win_en;
      outstanding_cnt=16'd5;
      load_shadow('h40_0000);  // 4 MiB capacity, comfortably > window
      do_commit();
      checks++;
      if (s_reject!==1'b1 || s_reason!==CFG_BUSY || s_committed!==1'b0 ||
          s_epoch!==exp_epoch || win_en!==active_en_snapshot) begin
        errors++; $display("[FAIL] D1 drain-gate: reject=%b reason=%0d committed=%b epoch=%0d(exp %0d)",
                           s_reject,s_reason,s_committed,s_epoch,exp_epoch);
      end else $display("[pass] D1 drain-gate rejects commit while outstanding");

      // D2: now drained — same config commits, epoch++, active reflects window 0 enabled
      outstanding_cnt=0;
      do_commit();     // shadow still holds the config
      checks++; exp_epoch++;
      if (s_committed!==1'b1 || s_epoch!==exp_epoch || win_en[0]!==1'b1) begin
        errors++; $display("[FAIL] D2 commit-when-drained: committed=%b epoch=%0d win_en=%b",s_committed,s_epoch,win_en);
      end else $display("[pass] D2 commit when drained (epoch=%0d, active updated)",s_epoch);

      // D3: atomicity — load an INVALID window-0 (unaligned base), commit ->
      // reject, active config must stay as the D2-committed one.
      active_en_snapshot = win_en;
      t_en[0]=1; t_base[0]='h0000_1020; t_size[0]='h0001_0000; t_dpa[0]=0; // base not 64B aligned
      load_shadow('h40_0000);
      do_commit();
      checks++;
      if (s_reject!==1'b1 || s_committed!==1'b0 || s_epoch!==exp_epoch || win_en!==active_en_snapshot) begin
        errors++; $display("[FAIL] D3 atomicity: reject=%b committed=%b epoch=%0d active=%b(snap %b)",
                           s_reject,s_committed,s_epoch,win_en,active_en_snapshot);
      end else $display("[pass] D3 rejected commit leaves active config unchanged (atomic)");
    end
  endtask

  initial begin
    sh_we=0; sh_en_i=0; sh_base_i=0; sh_size_i=0; sh_dpa_i=0; sh_cap_we=0; sh_cap_i=0;
    commit=0; sh_idx=0; outstanding_cnt=0;
    // reset
    dut_reset;
    run_file();
    directed();
    $display("=== checks=%0d errors=%0d ===", checks, errors);
    $display("TB_RESULT: %s", (errors==0)?"PASS":"FAIL");
    $finish;
  end

  task dut_reset; begin rst_n=0; repeat(3) @(negedge clk); rst_n=1; @(negedge clk); end endtask
endmodule
