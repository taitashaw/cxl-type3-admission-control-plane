// formal_async_fifo.sv — free-input wrapper proving async_fifo safety + end-to-end
// DATA INTEGRITY by UNBOUNDED INDUCTION under a genuine TWO-CLOCK model. wr_clk
// and rd_clk are independent formal clocks under a global clock (`gclk`); the
// solver freely chooses each domain's edges, covering all relative clock
// phases/frequencies (this is the model that encodes the MTBF assumption — a
// gray-coded crossing changes one bit, so a metastable sample lands on a legal
// old/new value the model already admits). See docs/cdc_reset_contract.md.
`ifndef W
 `define W 2
`endif
`ifndef A
 `define A 2
`endif
module formal_async_fifo #(
  parameter int unsigned WIDTH = `W,
  parameter int unsigned ADDR_W = `A
)( );
  localparam int unsigned PW    = ADDR_W + 1;
  localparam int unsigned DEPTH = (1 << ADDR_W);
  localparam int unsigned PMOD  = (1 << (ADDR_W + 1));   // pointer modulus 2**PW
  localparam int unsigned MASK  = PMOD - 1;
  logic wr_clk, rd_clk, wr_rst_n, rd_rst_n;
  logic wr_en, rd_en; logic [WIDTH-1:0] wr_data, rd_data;
  logic full, empty;
  logic [PW-1:0] dbg_wbin, dbg_wgray, dbg_rbin, dbg_rgray;
  logic [PW-1:0] dbg_wgray_s, dbg_rgray_s, dbg_wgray_s0, dbg_rgray_s0;
  logic [DEPTH*WIDTH-1:0] dbg_mem;

  async_fifo #(.WIDTH(WIDTH), .ADDR_W(ADDR_W)) dut (.*);

  (* gclk *) reg gclk;

  // reset asserted at t0 (basecase reachable init), released and held after
  reg started; initial started = 1'b0;
  always @(posedge gclk) started <= 1'b1;
  always @(posedge gclk) begin
    assume (wr_rst_n == started);
    assume (rd_rst_n == started);
  end

  function automatic logic [PW-1:0] b2g(input logic [PW-1:0] b); b2g = b ^ (b >> 1); endfunction
  function automatic logic [PW-1:0] g2b(input logic [PW-1:0] g);
    integer i; logic [PW-1:0] b;
    begin b[PW-1] = g[PW-1]; for (i = PW-2; i >= 0; i--) b[i] = g[i] ^ b[i+1]; g2b = b; end
  endfunction
  function automatic int unsigned dist(input logic [PW-1:0] a, input logic [PW-1:0] b);
    dist = (a - b) & MASK;             // forward distance mod 2**PW
  endfunction

  logic [PW-1:0] wb, rb, ws, ws0, rs, rs0;
  always_comb begin
    wb  = dbg_wbin;  rb  = dbg_rbin;
    ws  = g2b(dbg_wgray_s);  ws0 = g2b(dbg_wgray_s0);
    rs  = g2b(dbg_rgray_s);  rs0 = g2b(dbg_rgray_s0);
  end

  // ---- data-integrity ghost: symbolic write-pointer value + captured data ----
  (* anyconst *) logic [PW-1:0] f_wptr;
  logic [WIDTH-1:0] f_data;
  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) f_data <= '0;
    else if (wr_en && !full && dbg_wbin == f_wptr) f_data <= wr_data;
  end
  // f_wptr occupies a live slot iff its offset from rb is within the fill
  logic f_inflight;
  always_comb f_inflight = (dist(f_wptr, rb) < dist(wb, rb));

  // lag(X) = how far X trails the true write pointer wb (forward distance).
  // The physical order rs <= rs0 <= rb <= ws <= ws0 <= wb becomes a MONOTONE
  // lag chain lag(rs) >= lag(rs0) >= lag(rb) >= lag(ws) >= lag(ws0) >= 0, capped
  // at DEPTH. This single chain is inductive and yields no-overflow/underflow.
  int unsigned lag_rs, lag_rs0, lag_rb, lag_ws, lag_ws0;
  always_comb begin
    lag_rs  = dist(wb, rs);   lag_rs0 = dist(wb, rs0);  lag_rb = dist(wb, rb);
    lag_ws  = dist(wb, ws);   lag_ws0 = dist(wb, ws0);
  end

  always @(posedge gclk) begin
    if (started) begin
      // gray consistency of the true pointers
      assert (dbg_wgray == b2g(wb));
      assert (dbg_rgray == b2g(rb));
      // MONOTONE LAG CHAIN (the inductive core)
      assert (lag_rs  <= DEPTH);          // write side bounded by the full guard
      assert (lag_rs  >= lag_rs0);        // rs (2nd sync) trails rs0 (1st sync)
      assert (lag_rs0 >= lag_rb);         // rs0 trails the true read pointer
      assert (lag_rb  >= lag_ws);         // rb trails the synced write pointer
      assert (lag_ws  >= lag_ws0);        // ws (2nd sync) trails ws0 (1st sync)
      // SAFETY consequences: true occupancy in [0,DEPTH]; flags well-formed
      assert (lag_rb  <= DEPTH);          // no overflow / no underflow (rb never passes wb)
      assert (full  == (lag_rs == DEPTH));
      assert (empty == (lag_ws == lag_rb));
      // DATA INTEGRITY: a live slot holds the value written to it; the head read
      // therefore returns the correct FIFO-ordered datum.
      if (f_inflight) assert (dbg_mem[f_wptr[ADDR_W-1:0]*WIDTH +: WIDTH] == f_data);
      if (dbg_rbin == f_wptr && lag_rb >= 1) assert (rd_data == f_data);
    end
    // covers (non-vacuity)
    cover (started && full);
    cover (started && empty && dist(wb, rb) == 0 && wb != '0);
    cover (started && wr_en && !full && rd_en && !empty);      // simultaneous wr+rd
    cover (started && wb > PW'(DEPTH));                         // wrap-around
  end
endmodule
