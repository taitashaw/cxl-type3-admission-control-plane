// mem_subsys_top.sv
// M6 — memory datapath: rw_scheduler + mem_backend. Admitted transactions are
// scheduled (cross-address reorder, per-address program order preserved) to the
// behavioral memory, which returns tagged completions; the scheduler produces the
// transaction response. End-to-end: a read response returns the most recent write
// to the same address that was accepted before it (proved in the differential model
// via a shadow memory; composed from the scheduler's per-address ordering and the
// backend's in-accept-order application).
`ifndef MEM_SUBSYS_TOP_SV
`define MEM_SUBSYS_TOP_SV
module mem_subsys_top #(
  parameter int unsigned TAG_W    = 6,
  parameter int unsigned ADDR_W   = 4,
  parameter int unsigned DATA_W   = 8,
  parameter int unsigned DEPTH    = 4,     // scheduler pending table
  parameter int unsigned CQ_DEPTH = 4,     // backend completion FIFO
  parameter int unsigned IDX_W    = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
  parameter int unsigned OCC_W    = IDX_W + 1
) (
  input  logic              clk,
  input  logic              rst_n,
  // issue in
  input  logic              iss_valid,
  output logic              iss_ready,
  input  logic [TAG_W-1:0]  iss_tag,
  input  logic              iss_write,
  input  logic [ADDR_W-1:0] iss_addr,
  input  logic [DATA_W-1:0] iss_wdata,
  // response out
  output logic              rsp_valid,
  input  logic              rsp_ready,
  output logic [TAG_W-1:0]  rsp_tag,
  output logic [DATA_W-1:0] rsp_rdata,
  output logic [OCC_W-1:0]  occupancy,
  // debug/observation pass-through (for the end-to-end induction proof)
  output logic [DEPTH-1:0]         dbg_vld,
  output logic [DEPTH-1:0]         dbg_wr,
  output logic [DEPTH-1:0]         dbg_issd,
  output logic [DEPTH-1:0]         dbg_done,
  output logic [DEPTH*ADDR_W-1:0]  dbg_adr,
  output logic [DEPTH*DATA_W-1:0]  dbg_rdat,
  output logic [DEPTH*DATA_W-1:0]  dbg_wdat,
  output logic [DEPTH*TAG_W-1:0]   dbg_tag,
  output logic [DEPTH*DEPTH-1:0]   dbg_older,
  output logic [IDX_W-1:0]         dbg_alloc_slot,
  output logic [IDX_W-1:0]         dbg_rsp_slot,
  output logic [(1<<ADDR_W)*DATA_W-1:0] dbg_mem,
  // memory-issue observation (real ports; avoids fragile hierarchical refs)
  output logic                     dbg_mv,
  output logic                     dbg_mr,
  output logic                     dbg_mw,
  output logic [ADDR_W-1:0]        dbg_maddr,
  output logic [DATA_W-1:0]        dbg_mwdata,
  // backend completion-FIFO observation (for the end-to-end induction proof)
  output logic [CQ_DEPTH*TAG_W-1:0]  dbg_cq_tag,
  output logic [CQ_DEPTH*DATA_W-1:0] dbg_cq_data,
  output logic [((CQ_DEPTH<=1)?1:$clog2(CQ_DEPTH))-1:0] dbg_cq_head,
  output logic [$clog2(CQ_DEPTH+1)-1:0]                 dbg_cq_cnt
);
  // scheduler <-> backend
  logic              mem_valid, mem_ready, mem_write;
  logic [TAG_W-1:0]  mem_tag;
  logic [ADDR_W-1:0] mem_addr;
  logic [DATA_W-1:0] mem_wdata;
  logic              cmp_valid;
  logic [TAG_W-1:0]  cmp_tag;
  logic [DATA_W-1:0] cmp_rdata;
  assign dbg_mv = mem_valid; assign dbg_mr = mem_ready; assign dbg_mw = mem_write;
  assign dbg_maddr = mem_addr; assign dbg_mwdata = mem_wdata;

  rw_scheduler #(.TAG_W(TAG_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W), .DEPTH(DEPTH)) u_sch (
    .clk(clk), .rst_n(rst_n),
    .iss_valid(iss_valid), .iss_ready(iss_ready), .iss_tag(iss_tag), .iss_write(iss_write),
    .iss_addr(iss_addr), .iss_wdata(iss_wdata),
    .mem_valid(mem_valid), .mem_ready(mem_ready), .mem_tag(mem_tag), .mem_write(mem_write),
    .mem_addr(mem_addr), .mem_wdata(mem_wdata),
    .mc_valid(cmp_valid), .mc_tag(cmp_tag), .mc_rdata(cmp_rdata),
    .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
    .occupancy(occupancy),
    .dbg_vld(dbg_vld), .dbg_wr(dbg_wr), .dbg_issd(dbg_issd), .dbg_done(dbg_done),
    .dbg_adr(dbg_adr), .dbg_rdat(dbg_rdat), .dbg_wdat(dbg_wdat), .dbg_tag(dbg_tag),
    .dbg_older(dbg_older), .dbg_alloc_slot(dbg_alloc_slot), .dbg_rsp_slot(dbg_rsp_slot)
  );

  mem_backend #(.TAG_W(TAG_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W), .CQ_DEPTH(CQ_DEPTH)) u_be (
    .clk(clk), .rst_n(rst_n),
    .req_valid(mem_valid), .req_ready(mem_ready), .req_tag(mem_tag), .req_write(mem_write),
    .req_addr(mem_addr), .req_wdata(mem_wdata),
    .cmp_valid(cmp_valid), .cmp_ready(1'b1), .cmp_tag(cmp_tag), .cmp_rdata(cmp_rdata),
    .dbg_mem(dbg_mem),
    .dbg_cq_tag(dbg_cq_tag), .dbg_cq_data(dbg_cq_data), .dbg_cq_head(dbg_cq_head), .dbg_cq_cnt(dbg_cq_cnt)
  );

// Note: the structural "a response is a live done entry" property is proved inside
// rw_scheduler (rsp_valid => vld[rsp_sel] && done[rsp_sel]); the integration's unique
// property (end-to-end read-after-write) is checked in formal/formal_mem_subsys.sv
// and in the differential model's shadow-memory self-check.
endmodule
`endif
