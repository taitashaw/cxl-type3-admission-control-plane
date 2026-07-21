// formal_mem_backend.sv — free-input wrapper around mem_backend. Safety ASSERTS
// (FIFO accounting, ready/valid, head-entry integrity, write-reflected) live in the
// DUT under `ifdef FORMAL. This wrapper supplies free stimulus and COVER statements.
module formal_mem_backend #(
  parameter int unsigned TAG_W=2, ADDR_W=2, DATA_W=2, CQ_DEPTH=3
)( input logic clk );
  logic rst_n;
  logic req_valid, req_ready; logic [TAG_W-1:0] req_tag; logic req_write;
  logic [ADDR_W-1:0] req_addr; logic [DATA_W-1:0] req_wdata;
  logic cmp_valid, cmp_ready; logic [TAG_W-1:0] cmp_tag; logic [DATA_W-1:0] cmp_rdata;
  logic [(1<<ADDR_W)*DATA_W-1:0] dbg_mem;
  localparam int unsigned CPTR_W=(CQ_DEPTH<=1)?1:$clog2(CQ_DEPTH);
  localparam int unsigned CCNT_W=$clog2(CQ_DEPTH+1);
  logic [CQ_DEPTH*TAG_W-1:0] dbg_cq_tag; logic [CQ_DEPTH*DATA_W-1:0] dbg_cq_data;
  logic [CPTR_W-1:0] dbg_cq_head; logic [CCNT_W-1:0] dbg_cq_cnt;

  mem_backend #(.TAG_W(TAG_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W), .CQ_DEPTH(CQ_DEPTH)) dut (.*);

  initial assume (!rst_n);
  logic p_rst; always_ff @(posedge clk) p_rst <= rst_n;
  always @(posedge clk) begin
    cover (rst_n && req_valid && req_ready);                       // accept
    cover (rst_n && cmp_valid);                                    // a completion presented
    cover (rst_n && !req_ready);                                    // queue full (backpressure)
    cover (rst_n && cmp_valid && cmp_rdata != '0);                 // a read returned nonzero data
    cover (p_rst == 1'b0 && rst_n == 1'b1);                        // reset deasserts
  end
endmodule
