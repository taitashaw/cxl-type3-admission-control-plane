// rw_scheduler.sv
// M5 — read/write scheduler after the admission control plane. Accepts admitted
// transactions, schedules them to an abstract tagged memory backend with
// cross-address REORDERING but per-address PROGRAM ORDER preserved by a hazard
// interlock (a younger same-address access cannot issue to memory until every
// older same-address access has completed). Program order is tracked by an age
// matrix (older[i][j] = i older than j) with no wrapping sequence numbers.
// Safety only — no liveness/fairness claim. See docs/scheduler_contract.md.
`ifndef RW_SCHEDULER_SV
`define RW_SCHEDULER_SV
module rw_scheduler #(
  parameter int unsigned TAG_W  = 6,
  parameter int unsigned ADDR_W = 8,
  parameter int unsigned DATA_W = 8,
  parameter int unsigned DEPTH  = 4,
  parameter int unsigned IDX_W  = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
  parameter int unsigned OCC_W  = IDX_W + 1
) (
  input  logic              clk,
  input  logic              rst_n,

  // ---- issue in (from admission downstream) ----
  input  logic              iss_valid,
  output logic              iss_ready,
  input  logic [TAG_W-1:0]  iss_tag,
  input  logic              iss_write,
  input  logic [ADDR_W-1:0] iss_addr,
  input  logic [DATA_W-1:0] iss_wdata,

  // ---- memory out ----
  output logic              mem_valid,
  input  logic              mem_ready,
  output logic [TAG_W-1:0]  mem_tag,
  output logic              mem_write,
  output logic [ADDR_W-1:0] mem_addr,
  output logic [DATA_W-1:0] mem_wdata,

  // ---- memory completion in (tagged; targets one issued not-done entry) ----
  input  logic              mc_valid,
  input  logic [TAG_W-1:0]  mc_tag,
  input  logic [DATA_W-1:0] mc_rdata,

  // ---- response out (to tracker retire) ----
  output logic              rsp_valid,
  input  logic              rsp_ready,
  output logic [TAG_W-1:0]  rsp_tag,
  output logic [DATA_W-1:0] rsp_rdata,

  // ---- observability ----
  output logic [OCC_W-1:0]  occupancy
);
  // ---- per-slot state ----
  logic              vld  [DEPTH];
  logic [TAG_W-1:0]  tag  [DEPTH];
  logic              wr   [DEPTH];
  logic [ADDR_W-1:0] adr  [DEPTH];
  logic [DATA_W-1:0] wdat [DEPTH];
  logic              issd [DEPTH];
  logic              done [DEPTH];
  logic [DATA_W-1:0] rdat [DEPTH];
  logic [DEPTH-1:0]  older[DEPTH];        // older[i][j] == entry i is older than j

  // ---- free slot (lowest !valid) ----
  logic [IDX_W-1:0] free_slot;
  logic             have_free;
  always_comb begin
    have_free = 1'b0; free_slot = '0;
    for (int i = DEPTH-1; i >= 0; i--) if (!vld[i]) begin have_free = 1'b1; free_slot = i[IDX_W-1:0]; end
  end
  assign iss_ready = rst_n && have_free;
  logic accept; assign accept = iss_valid && iss_ready;

  // ---- eligibility: not blocked by an older same-address un-done entry ----
  logic [DEPTH-1:0] elig;
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      logic blk;
      blk = 1'b0;
      for (int j = 0; j < DEPTH; j++)
        if (vld[j] && older[j][i] && (adr[j] == adr[i]) && !done[j]) blk = 1'b1;
      elig[i] = vld[i] && !issd[i] && !blk;
    end
  end
  // memory issue = lowest-index eligible entry
  logic [IDX_W-1:0] mem_sel;
  always_comb begin
    mem_valid = 1'b0; mem_sel = '0;
    for (int i = DEPTH-1; i >= 0; i--) if (elig[i]) begin mem_valid = 1'b1; mem_sel = i[IDX_W-1:0]; end
  end
  assign mem_tag   = tag[mem_sel];
  assign mem_write = wr[mem_sel];
  assign mem_addr  = adr[mem_sel];
  assign mem_wdata = wdat[mem_sel];

  // ---- completion match (unique issued not-done entry with tag==mc_tag) ----
  logic [DEPTH-1:0] mc_hit;
  always_comb
    for (int i = 0; i < DEPTH; i++)
      mc_hit[i] = mc_valid && vld[i] && issd[i] && !done[i] && (tag[i] == mc_tag);

  // ---- response = lowest-index live done entry ----
  logic [IDX_W-1:0] rsp_sel;
  always_comb begin
    rsp_valid = 1'b0; rsp_sel = '0;
    for (int i = DEPTH-1; i >= 0; i--) if (vld[i] && done[i]) begin rsp_valid = 1'b1; rsp_sel = i[IDX_W-1:0]; end
  end
  assign rsp_tag   = tag[rsp_sel];
  assign rsp_rdata = rdat[rsp_sel];

  // ---- occupancy ----
  always_comb begin
    occupancy = '0;
    for (int i = 0; i < DEPTH; i++) if (vld[i]) occupancy = occupancy + OCC_W'(1);
  end

  logic do_mem, do_rsp;
  assign do_mem = mem_valid && mem_ready;
  assign do_rsp = rsp_valid && rsp_ready;

  // ---- sequential ----
  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (k = 0; k < DEPTH; k++) begin
        vld[k]<=1'b0; issd[k]<=1'b0; done[k]<=1'b0; older[k]<='0;
        tag[k]<='0; wr[k]<=1'b0; adr[k]<='0; wdat[k]<='0; rdat[k]<='0;
      end
    end else begin
      // free the responded entry (slot reusable)
      if (do_rsp) begin vld[rsp_sel]<=1'b0; issd[rsp_sel]<=1'b0; done[rsp_sel]<=1'b0; end
      // mark issued
      if (do_mem) issd[mem_sel]<=1'b1;
      // completion: mark done + latch read data
      for (k = 0; k < DEPTH; k++) if (mc_hit[k]) begin done[k]<=1'b1; rdat[k]<=mc_rdata; end
      // accept a new transaction into the free slot; establish its age
      if (accept) begin
        vld[free_slot]<=1'b1; tag[free_slot]<=iss_tag; wr[free_slot]<=iss_write;
        adr[free_slot]<=iss_addr; wdat[free_slot]<=iss_wdata; issd[free_slot]<=1'b0; done[free_slot]<=1'b0;
        for (k = 0; k < DEPTH; k++) begin
          older[free_slot][k] <= 1'b0;                  // youngest: older than nobody
          if (k[IDX_W-1:0] != free_slot) older[k][free_slot] <= vld[k]; // every live entry is older
        end
      end
    end
  end

`ifdef FORMAL
  logic f_init; initial f_init = 1'b0;
  logic f_prst; always_ff @(posedge clk) begin f_init<=1'b1; f_prst<=rst_n; end
  logic [OCC_W-1:0] vpop;
  always_comb begin vpop='0; for (int i=0;i<DEPTH;i++) if (vld[i]) vpop=vpop+OCC_W'(1); end
  logic [DATA_W-1:0] f_pmc; logic f_pmch;
  always_ff @(posedge clk) begin f_pmc<=mc_rdata; f_pmch<=mc_hit[0]; end
  always @(posedge clk) begin
    if (rst_n && f_init) begin
      assert (occupancy == vpop);
      assert (occupancy <= OCC_W'(DEPTH));
      assert (iss_ready == (rst_n && have_free));
      for (int i = 0; i < DEPTH; i++) begin
        assert (!older[i][i]);                            // irreflexive
        if (vld[i] && done[i]) assert (issd[i]);          // done => issued
        // AGE is a strict total order over live entries
        for (int j = 0; j < DEPTH; j++)
          if (i != j && vld[i] && vld[j]) assert (older[i][j] ^ older[j][i]);
        // PER-ADDRESS ORDER: a younger same-address issued entry implies the
        // older same-address entry has completed (no same-addr reorder at memory)
        for (int j = 0; j < DEPTH; j++)
          if (vld[i] && vld[j] && older[i][j] && (adr[i]==adr[j]) && issd[j]) assert (done[i]);
      end
      // a memory issue is eligible: no older same-address un-done entry
      if (mem_valid) begin
        assert (vld[mem_sel] && !issd[mem_sel]);
        for (int j = 0; j < DEPTH; j++)
          if (vld[j] && older[j][mem_sel] && (adr[j]==adr[mem_sel])) assert (done[j]);
      end
      // response only for a live done entry; integrity of tag
      if (rsp_valid) assert (vld[rsp_sel] && done[rsp_sel] && rsp_tag == tag[rsp_sel]);
      // an issue targets a live, not-done entry with the exposed tag
      if (mem_valid) assert (mem_tag == tag[mem_sel]);
    end
  end
`endif
endmodule
`endif
