// async_fifo.sv
// M7 — dual-clock FIFO with gray-coded pointer crossing and two-flop pointer
// synchronizers. DEPTH = 2**ADDR_W (power of two, required for gray wrap).
// ADDR_W >= 2. Safety only; metastability resolution is an ASSUMPTION (the
// gray code guarantees a single-bit change so a metastable sample resolves to
// a legal old/new value). See docs/cdc_reset_contract.md.
`ifndef ASYNC_FIFO_SV
`define ASYNC_FIFO_SV
module async_fifo #(
  parameter int unsigned WIDTH  = 8,
  parameter int unsigned ADDR_W = 3            // DEPTH = 2**ADDR_W, ADDR_W >= 2
) (
  // write domain
  input  logic              wr_clk,
  input  logic              wr_rst_n,
  input  logic              wr_en,
  input  logic [WIDTH-1:0]  wr_data,
  output logic              full,
  // read domain
  input  logic              rd_clk,
  input  logic              rd_rst_n,
  input  logic              rd_en,
  output logic [WIDTH-1:0]  rd_data,
  output logic              empty,
  // flat observation ports (let an integration/formal top prove properties by
  // induction without a cross-module array index)
  output logic [ADDR_W:0]   dbg_wbin,
  output logic [ADDR_W:0]   dbg_wgray,
  output logic [ADDR_W:0]   dbg_rbin,
  output logic [ADDR_W:0]   dbg_rgray,
  output logic [ADDR_W:0]   dbg_wgray_s,      // write ptr synced into read domain (stage1)
  output logic [ADDR_W:0]   dbg_rgray_s,      // read ptr synced into write domain (stage1)
  output logic [ADDR_W:0]   dbg_wgray_s0,     // write ptr sync stage0 (mid)
  output logic [ADDR_W:0]   dbg_rgray_s0,     // read ptr sync stage0 (mid)
  output logic [(1<<ADDR_W)*WIDTH-1:0] dbg_mem
);
  localparam int unsigned DEPTH = (1 << ADDR_W);
  localparam int unsigned PW    = ADDR_W + 1;         // pointer width (extra MSB)

  logic [WIDTH-1:0] mem [DEPTH];

  logic [PW-1:0] wbin, wgray, wbin_n, wgray_n;
  logic [PW-1:0] rbin, rgray, rbin_n, rgray_n;
  logic [PW-1:0] wgray_s, rgray_s;

  function automatic logic [PW-1:0] b2g(input logic [PW-1:0] b);
    b2g = b ^ (b >> 1);
  endfunction

  // ---- write domain ----
  assign wbin_n  = wbin + (wr_en && !full ? PW'(1) : PW'(0));
  assign wgray_n = b2g(wbin_n);
  // full: write gray has lapped read gray by DEPTH (top two gray bits inverted,
  // the remaining bits equal).
  assign full = (wgray == {~rgray_s[PW-1:PW-2], rgray_s[PW-3:0]});

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wbin <= '0; wgray <= '0;
    end else begin
      wbin <= wbin_n; wgray <= wgray_n;
      if (wr_en && !full) mem[wbin[ADDR_W-1:0]] <= wr_data;
    end
  end

  // ---- read domain ----
  assign rbin_n  = rbin + (rd_en && !empty ? PW'(1) : PW'(0));
  assign rgray_n = b2g(rbin_n);
  assign empty   = (rgray == wgray_s);
  assign rd_data = mem[rbin[ADDR_W-1:0]];             // first-word head read

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rbin <= '0; rgray <= '0;
    end else begin
      rbin <= rbin_n; rgray <= rgray_n;
    end
  end

  // ---- pointer synchronizers (2-flop) ----
  logic [2*PW-1:0] w2r_chain, r2w_chain;
  sync_bits #(.WIDTH(PW), .STAGES(2)) u_w2r (
    .clk_dst(rd_clk), .rst_dst_n(rd_rst_n), .d_src(wgray), .q_dst(wgray_s), .dbg_sync(w2r_chain));
  sync_bits #(.WIDTH(PW), .STAGES(2)) u_r2w (
    .clk_dst(wr_clk), .rst_dst_n(wr_rst_n), .d_src(rgray), .q_dst(rgray_s), .dbg_sync(r2w_chain));
  assign dbg_wgray_s0 = w2r_chain[0 +: PW];    // stage0 (first flop) of w->r sync
  assign dbg_rgray_s0 = r2w_chain[0 +: PW];    // stage0 (first flop) of r->w sync

  // ---- observation ----
  assign dbg_wbin = wbin;   assign dbg_wgray = wgray;
  assign dbg_rbin = rbin;   assign dbg_rgray = rgray;
  assign dbg_wgray_s = wgray_s; assign dbg_rgray_s = rgray_s;
  genvar gi;
  generate for (gi = 0; gi < DEPTH; gi++) begin : g_dbg_mem
    assign dbg_mem[gi*WIDTH +: WIDTH] = mem[gi];
  end endgenerate
endmodule
`endif
