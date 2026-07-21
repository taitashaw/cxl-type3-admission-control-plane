// mem_backend.sv
// M6 — behavioral memory backend (DDR4 model, timing-abstracted) that services the
// rw_scheduler's tagged memory port. One request/cycle, processed in accept order:
// a write updates mem[addr], a read captures mem[addr]; each request enqueues a
// completion {tag, rdata} into a FIFO whose head is presented to the scheduler.
// NOT a physical-DDR model: no tRCD/tRP/refresh/bank/burst/ECC timing. Safety only.
`ifndef MEM_BACKEND_SV
`define MEM_BACKEND_SV
module mem_backend #(
  parameter int unsigned TAG_W    = 6,
  parameter int unsigned ADDR_W   = 4,
  parameter int unsigned DATA_W   = 8,
  parameter int unsigned CQ_DEPTH = 4,                     // completion FIFO depth
  parameter int unsigned MEM_N    = (1 << ADDR_W),
  parameter int unsigned CPTR_W   = (CQ_DEPTH <= 1) ? 1 : $clog2(CQ_DEPTH),
  parameter int unsigned CCNT_W   = $clog2(CQ_DEPTH + 1)
) (
  input  logic              clk,
  input  logic              rst_n,
  // request in
  input  logic              req_valid,
  output logic              req_ready,
  input  logic [TAG_W-1:0]  req_tag,
  input  logic              req_write,
  input  logic [ADDR_W-1:0] req_addr,
  input  logic [DATA_W-1:0] req_wdata,
  // completion out (the scheduler ties cmp_ready=1; a completion FIFO absorbs any
  // backpressure so the request side can still accept)
  output logic              cmp_valid,
  input  logic              cmp_ready,
  output logic [TAG_W-1:0]  cmp_tag,
  output logic [DATA_W-1:0] cmp_rdata,
  // debug/observation: flat memory array (lets an integration prove end-to-end
  // read-after-write by induction without a cross-module array index).
  output logic [MEM_N*DATA_W-1:0] dbg_mem,
  output logic [CQ_DEPTH*TAG_W-1:0]  dbg_cq_tag,
  output logic [CQ_DEPTH*DATA_W-1:0] dbg_cq_data,
  output logic [CPTR_W-1:0]          dbg_cq_head,
  output logic [CCNT_W-1:0]          dbg_cq_cnt
);
  // ---- memory array ----
  logic [DATA_W-1:0] mem [MEM_N];

  // ---- completion FIFO ----
  logic [TAG_W-1:0]  cq_tag  [CQ_DEPTH];
  logic [DATA_W-1:0] cq_data [CQ_DEPTH];
  logic [CPTR_W-1:0] head, tail;
  logic [CCNT_W-1:0] cnt;

  assign req_ready = rst_n && (cnt != CCNT_W'(CQ_DEPTH));
  logic accept; assign accept = req_valid && req_ready;

  assign cmp_valid = (cnt != '0);
  assign cmp_tag   = cmp_valid ? cq_tag[head]  : '0;       // 0 when empty (deterministic)
  assign cmp_rdata = cmp_valid ? cq_data[head] : '0;
  logic pop; assign pop = cmp_valid && cmp_ready;          // consumed on handshake

  logic [DATA_W-1:0] rd_val;
  assign rd_val = mem[req_addr];                           // pre-edge read value

  genvar gm;
  generate for (gm = 0; gm < MEM_N; gm++) begin : g_dbg_mem
    assign dbg_mem[gm*DATA_W +: DATA_W] = mem[gm];
  end endgenerate
  genvar gq;
  generate for (gq = 0; gq < CQ_DEPTH; gq++) begin : g_dbg_cq
    assign dbg_cq_tag[gq*TAG_W +: TAG_W]   = cq_tag[gq];
    assign dbg_cq_data[gq*DATA_W +: DATA_W] = cq_data[gq];
  end endgenerate
  assign dbg_cq_head = head; assign dbg_cq_cnt = cnt;

  function automatic logic [CPTR_W-1:0] pinc(input logic [CPTR_W-1:0] p);
    if (p == CPTR_W'(CQ_DEPTH-1)) pinc = '0;
    else                          pinc = p + CPTR_W'(1);
  endfunction

  integer i;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      head <= '0; tail <= '0; cnt <= '0;
      for (i = 0; i < MEM_N; i++) mem[i] <= '0;
      for (i = 0; i < CQ_DEPTH; i++) begin cq_tag[i] <= '0; cq_data[i] <= '0; end
    end else begin
      // accept: process + enqueue a completion
      if (accept) begin
        if (req_write) mem[req_addr] <= req_wdata;
        cq_tag[tail]  <= req_tag;
        cq_data[tail] <= req_write ? '0 : rd_val;          // read returns captured value
        tail          <= pinc(tail);
      end
      if (pop) head <= pinc(head);
      // count update (simultaneous push/pop nets out)
      cnt <= cnt + (accept ? CCNT_W'(1) : '0) - (pop ? CCNT_W'(1) : '0);
    end
  end

`ifdef FORMAL
  logic f_init; initial f_init = 1'b0;
  logic f_prst; always_ff @(posedge clk) begin f_init<=1'b1; f_prst<=rst_n; end
  always @(posedge clk) begin
    if (rst_n && f_init) begin
      assert (cnt <= CCNT_W'(CQ_DEPTH));                   // bounded
      assert (req_ready == (cnt != CCNT_W'(CQ_DEPTH)));    // ready iff room
      assert (cmp_valid == (cnt != '0));                   // valid iff non-empty
      assert ({{(32-CPTR_W){1'b0}}, head} < CQ_DEPTH);     // head in range
      assert ({{(32-CPTR_W){1'b0}}, tail} < CQ_DEPTH);     // tail in range
      // FIFO structural consistency: the occupied region is EXACTLY the cnt
      // entries at [head, head+cnt) (mod CQ_DEPTH), i.e. tail = (head+cnt) mod
      // CQ_DEPTH. Needed so an integration proof can trust that the head/occupied
      // entries are the genuinely-enqueued ones (not stale storage).
      begin
        logic [31:0] sum_hc, tmod;
        sum_hc = {{(32-CPTR_W){1'b0}}, head} + {{(32-CCNT_W){1'b0}}, cnt};
        tmod   = (sum_hc >= CQ_DEPTH) ? (sum_hc - CQ_DEPTH) : sum_hc;
        assert (tmod == {{(32-CPTR_W){1'b0}}, tail});
      end
      // the head entry's tag/data come from the FIFO storage (no corruption)
      if (cmp_valid) assert (cmp_tag == cq_tag[head] && cmp_rdata == cq_data[head]);
      // a write is reflected in the array immediately (next-cycle read sees it)
      if ($past(rst_n) && $past(req_valid && req_ready && req_write))
        assert (mem[$past(req_addr)] == $past(req_wdata));
    end
  end
`endif
endmodule
`endif
