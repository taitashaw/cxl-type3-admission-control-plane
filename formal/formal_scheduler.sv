// formal_scheduler.sv — free-input wrapper around rw_scheduler. Safety ASSERTS
// (age strict total order, per-address ordering interlock, done=>issued, response
// integrity, occupancy) live in the DUT under `ifdef FORMAL. This wrapper supplies
// free stimulus and COVER statements. A small address space (ADDR_W small) makes
// same-address hazards reachable.
module formal_scheduler #(
  parameter int unsigned TAG_W  = 2,
  parameter int unsigned ADDR_W = 1,
  parameter int unsigned DATA_W = 2,
  parameter int unsigned DEPTH  = 3,
  parameter int unsigned IDX_W  = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
  parameter int unsigned OCC_W  = IDX_W + 1
)( input logic clk );
  logic rst_n;
  logic iss_valid, iss_ready; logic [TAG_W-1:0] iss_tag; logic iss_write;
  logic [ADDR_W-1:0] iss_addr; logic [DATA_W-1:0] iss_wdata;
  logic mem_valid, mem_ready; logic [TAG_W-1:0] mem_tag; logic mem_write;
  logic [ADDR_W-1:0] mem_addr; logic [DATA_W-1:0] mem_wdata;
  logic mc_valid; logic [TAG_W-1:0] mc_tag; logic [DATA_W-1:0] mc_rdata;
  logic rsp_valid, rsp_ready; logic [TAG_W-1:0] rsp_tag; logic [DATA_W-1:0] rsp_rdata;
  logic [OCC_W-1:0] occupancy;
  logic [DEPTH-1:0] dbg_vld, dbg_wr, dbg_issd, dbg_done;
  logic [DEPTH*ADDR_W-1:0] dbg_adr; logic [DEPTH*DATA_W-1:0] dbg_rdat;
  logic [DEPTH*DATA_W-1:0] dbg_wdat; logic [DEPTH*TAG_W-1:0] dbg_tag; logic [DEPTH*DEPTH-1:0] dbg_older;
  logic [IDX_W-1:0] dbg_alloc_slot, dbg_rsp_slot;

  rw_scheduler #(.TAG_W(TAG_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W), .DEPTH(DEPTH)) dut (.*);

  initial assume (!rst_n);
  logic p_rst; logic [OCC_W-1:0] p_occ;
  always_ff @(posedge clk) begin p_rst <= rst_n; p_occ <= occupancy; end

  // a live, not-issued entry that is currently blocked by the hazard interlock
  logic some_blocked;
  always_comb begin
    some_blocked = 1'b0;
    for (int i = 0; i < DEPTH; i++)
      if (dut.vld[i] && !dut.issd[i] && !dut.elig[i]) some_blocked = 1'b1;
  end

  always @(posedge clk) begin
    cover (rst_n && iss_valid && iss_ready);                 // accept
    cover (rst_n && mem_valid && mem_ready);                 // memory issue
    cover (rst_n && mc_valid && (|dut.mc_hit));              // completion
    cover (rst_n && rsp_valid && rsp_ready);                 // response
    cover (rst_n && occupancy == OCC_W'(DEPTH));             // full
    cover (!rst_n && p_occ != 0);                            // reset with live entries
    cover (p_rst == 1'b0 && rst_n == 1'b1);                  // reset deasserts
  end

  // same-address interlock and reorder need >=2 live entries
  generate if (DEPTH > 1) begin : g_multi
    always @(posedge clk) begin
      cover (rst_n && some_blocked);                           // same-address interlock active
      cover (rst_n && some_blocked && mem_valid && mem_ready); // reorder AROUND a blocked entry
    end
  end endgenerate
endmodule
