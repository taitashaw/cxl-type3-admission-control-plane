// system_top.sv
// M8 — in-system CDC integration at the admission -> scheduler seam. Admitted
// requests {tag,write,addr,wdata} produced by the (already-verified M1-M4)
// decode + control-plane front-end in the LINK clock domain are carried across
// an async_fifo CDC bridge into the MEMORY clock domain, serviced by the
// verified mem_subsys_top (M5/M6), and the {tag,rdata} responses are carried
// back across a second async_fifo CDC bridge into the link domain.
//
// Result-class discipline (see docs/system_integration_contract.md):
//  - the two CDC bridges' data integrity / no-overflow-underflow are proved by
//    INDUCTION at the exact payload widths (async_fifo proof, composed);
//  - the block behaviours are composed from their own M1-M6 induction proofs;
//  - the full request->response functional path is RTL_SIMULATED (differential).
`ifndef SYSTEM_TOP_SV
`define SYSTEM_TOP_SV
module system_top #(
  parameter int unsigned TAG_W    = 6,
  parameter int unsigned ADDR_W   = 4,
  parameter int unsigned DATA_W   = 8,
  parameter int unsigned DEPTH    = 4,     // scheduler pending table
  parameter int unsigned CQ_DEPTH = 4,     // backend completion FIFO
  parameter int unsigned FIFO_AW  = 2,     // CDC FIFO depth = 2**FIFO_AW (>=2)
  parameter int unsigned IDX_W    = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
  parameter int unsigned OCC_W    = IDX_W + 1
) (
  // ---- link (front-end) clock domain ----
  input  logic              link_clk,
  input  logic              link_rst_n,
  // admitted-request in (from control_plane_top issue side + payload)
  input  logic              iss_valid,
  output logic              iss_ready,
  input  logic [TAG_W-1:0]  iss_tag,
  input  logic              iss_write,
  input  logic [ADDR_W-1:0] iss_addr,
  input  logic [DATA_W-1:0] iss_wdata,
  // response out (to control_plane_top retire side)
  output logic              rsp_valid,
  input  logic              rsp_ready,
  output logic [TAG_W-1:0]  rsp_tag,
  output logic [DATA_W-1:0] rsp_rdata,
  // ---- memory (back-end) clock domain ----
  input  logic              mem_clk,
  input  logic              mem_rst_n,
  // observation
  output logic [OCC_W-1:0]  occupancy
);
  localparam int unsigned REQ_W = TAG_W + 1 + ADDR_W + DATA_W;  // {tag,write,addr,wdata}
  localparam int unsigned RSP_W = TAG_W + DATA_W;               // {tag,rdata}

  // ================= request CDC bridge : link -> mem =================
  logic             req_full, req_empty;
  logic [REQ_W-1:0] req_din, req_dout;
  logic             ms_iss_valid, ms_iss_ready, req_pop;
  assign req_din   = {iss_tag, iss_write, iss_addr, iss_wdata};
  assign iss_ready = link_rst_n && !req_full;
  assign ms_iss_valid = !req_empty;
  assign req_pop   = ms_iss_valid && ms_iss_ready;             // mem side consumes

  async_fifo #(.WIDTH(REQ_W), .ADDR_W(FIFO_AW)) u_req_cdc (
    .wr_clk(link_clk), .wr_rst_n(link_rst_n), .wr_en(iss_valid && !req_full),
    .wr_data(req_din), .full(req_full),
    .rd_clk(mem_clk),  .rd_rst_n(mem_rst_n),  .rd_en(req_pop),
    .rd_data(req_dout), .empty(req_empty));

  // unpack the admitted request on the memory side
  logic [TAG_W-1:0]  ms_iss_tag;
  logic              ms_iss_write;
  logic [ADDR_W-1:0] ms_iss_addr;
  logic [DATA_W-1:0] ms_iss_wdata;
  assign {ms_iss_tag, ms_iss_write, ms_iss_addr, ms_iss_wdata} = req_dout;

  // ================= memory subsystem (mem clock domain) =================
  logic              ms_rsp_valid, ms_rsp_ready;
  logic [TAG_W-1:0]  ms_rsp_tag;
  logic [DATA_W-1:0] ms_rsp_rdata;

  mem_subsys_top #(.TAG_W(TAG_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W), .DEPTH(DEPTH), .CQ_DEPTH(CQ_DEPTH)) u_mem (
    .clk(mem_clk), .rst_n(mem_rst_n),
    .iss_valid(ms_iss_valid), .iss_ready(ms_iss_ready),
    .iss_tag(ms_iss_tag), .iss_write(ms_iss_write), .iss_addr(ms_iss_addr), .iss_wdata(ms_iss_wdata),
    .rsp_valid(ms_rsp_valid), .rsp_ready(ms_rsp_ready), .rsp_tag(ms_rsp_tag), .rsp_rdata(ms_rsp_rdata),
    .occupancy(occupancy));

  // ================= response CDC bridge : mem -> link =================
  logic             rsp_full, rsp_empty;
  logic [RSP_W-1:0] rsp_din, rsp_dout;
  assign rsp_din      = {ms_rsp_tag, ms_rsp_rdata};
  assign ms_rsp_ready = !rsp_full;
  assign rsp_valid    = link_rst_n && !rsp_empty;

  async_fifo #(.WIDTH(RSP_W), .ADDR_W(FIFO_AW)) u_rsp_cdc (
    .wr_clk(mem_clk),  .wr_rst_n(mem_rst_n),  .wr_en(ms_rsp_valid && !rsp_full),
    .wr_data(rsp_din), .full(rsp_full),
    .rd_clk(link_clk), .rd_rst_n(link_rst_n), .rd_en(rsp_valid && rsp_ready),
    .rd_data(rsp_dout), .empty(rsp_empty));

  assign {rsp_tag, rsp_rdata} = rsp_dout;
endmodule
`endif
