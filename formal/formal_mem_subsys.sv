// formal_mem_subsys.sv — free-input wrapper around mem_subsys_top proving the
// END-TO-END read-after-write property by UNBOUNDED INDUCTION using the flat
// debug/observation ports (no cross-module array index). For a symbolic address
// f_addr, a read response returns the last write to f_addr accepted at the issue
// port (program order) before it.
//
// Strengthening invariants (all over f_addr):
//   M   : mem[f_addr] == gW, where gW ghosts the last write to f_addr issued to the
//         backend (memory reflects the last processed write).
//   R0  : a read with NO live write to f_addr older than it expects mem[f_addr].
//   R1  : a read whose youngest live older write to f_addr is w expects wd(w).
//   I4  : a completed read to f_addr carries its expected value.
// From M + R0 + the scheduler's proved per-address order (younger same-addr issued
// => older done, compiled in), an issued read has no older un-done same-addr entry,
// so R0 gives mem[f_addr]==rexp, hence I4 and the response property.
module formal_mem_subsys #(
  parameter int unsigned TAG_W=2, ADDR_W=1, DATA_W=2, DEPTH=2, CQ_DEPTH=2,
  parameter int unsigned IDX_W=(DEPTH<=1)?1:$clog2(DEPTH), OCC_W=IDX_W+1,
  parameter int unsigned CPTR_W=(CQ_DEPTH<=1)?1:$clog2(CQ_DEPTH),
  parameter int unsigned CCNT_W=$clog2(CQ_DEPTH+1)
)( input logic clk );
  logic rst_n;
  logic iss_valid, iss_ready; logic [TAG_W-1:0] iss_tag; logic iss_write;
  logic [ADDR_W-1:0] iss_addr; logic [DATA_W-1:0] iss_wdata;
  logic rsp_valid, rsp_ready; logic [TAG_W-1:0] rsp_tag; logic [DATA_W-1:0] rsp_rdata;
  logic [OCC_W-1:0] occupancy;
  logic [DEPTH-1:0] dbg_vld, dbg_wr, dbg_issd, dbg_done;
  logic [DEPTH*ADDR_W-1:0] dbg_adr; logic [DEPTH*DATA_W-1:0] dbg_rdat, dbg_wdat;
  logic [DEPTH*TAG_W-1:0] dbg_tag;
  logic [DEPTH*DEPTH-1:0] dbg_older;
  logic [IDX_W-1:0] dbg_alloc_slot, dbg_rsp_slot;
  logic [(1<<ADDR_W)*DATA_W-1:0] dbg_mem;
  logic dbg_mv, dbg_mr, dbg_mw; logic [ADDR_W-1:0] dbg_maddr; logic [DATA_W-1:0] dbg_mwdata;
  logic [CQ_DEPTH*TAG_W-1:0]  dbg_cq_tag;
  logic [CQ_DEPTH*DATA_W-1:0] dbg_cq_data;
  logic [CPTR_W-1:0] dbg_cq_head; logic [CCNT_W-1:0] dbg_cq_cnt;

  mem_subsys_top #(.TAG_W(TAG_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W), .DEPTH(DEPTH), .CQ_DEPTH(CQ_DEPTH)) dut (.*);

  initial assume (!rst_n);
  logic f_init; initial f_init = 1'b0;
  always_ff @(posedge clk) f_init <= 1'b1;

  // Environment guarantee from the upstream tracker/admission layer (M2-M4):
  // live in-flight transactions carry UNIQUE tags. Enforced here as an input
  // constraint on the accepted tag so uniqueness is inductive from reset (no
  // live entries) forward. This makes the FIFO tag<->slot correlation 1:1.
  always @(posedge clk)
    if (rst_n && iss_valid && iss_ready)
      for (int i = 0; i < DEPTH; i++)
        if (dbg_vld[i]) assume (iss_tag != stag(i));

  (* anyconst *) logic [ADDR_W-1:0] f_addr;
  logic [DATA_W-1:0] shadow, gW;
  logic [DATA_W-1:0] rexp [DEPTH];
  logic iss_accept; assign iss_accept = iss_valid && iss_ready;
  logic [DATA_W-1:0] mem_fa; assign mem_fa = dbg_mem[f_addr*DATA_W +: DATA_W];

  function automatic logic isr(input int s);
    isr = dbg_vld[s] && !dbg_wr[s] && (dbg_adr[s*ADDR_W +: ADDR_W] == f_addr);
  endfunction
  function automatic logic isw(input int s);
    isw = dbg_vld[s] && dbg_wr[s] && (dbg_adr[s*ADDR_W +: ADDR_W] == f_addr);
  endfunction
  function automatic logic older(input int a, input int b); older = dbg_older[a*DEPTH + b]; endfunction
  function automatic logic [DATA_W-1:0] rd(input int s); rd = dbg_rdat[s*DATA_W +: DATA_W]; endfunction
  function automatic logic [DATA_W-1:0] wd(input int s); wd = dbg_wdat[s*DATA_W +: DATA_W]; endfunction
  function automatic logic [TAG_W-1:0]  stag(input int s); stag = dbg_tag[s*TAG_W +: TAG_W]; endfunction
  function automatic logic [TAG_W-1:0]  cqtag(input int q); cqtag = dbg_cq_tag[q*TAG_W +: TAG_W]; endfunction
  function automatic logic [DATA_W-1:0] cqdat(input int q); cqdat = dbg_cq_data[q*DATA_W +: DATA_W]; endfunction
  // FIFO slot q is occupied iff its circular distance from head is < cnt
  function automatic logic cq_occ(input int q);
    logic [31:0] dist;
    dist = (q >= dbg_cq_head) ? (q - dbg_cq_head)
                             : (q + CQ_DEPTH - dbg_cq_head);
    cq_occ = ({{(32-CCNT_W){1'b0}}, dbg_cq_cnt} != 0) && (dist < {{(32-CCNT_W){1'b0}}, dbg_cq_cnt});
  endfunction

  integer fi;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shadow <= '0; gW <= '0;
      for (fi = 0; fi < DEPTH; fi++) rexp[fi] <= '0;
    end else begin
      if (iss_accept) begin
        if (iss_write && iss_addr == f_addr)  shadow <= iss_wdata;
        if (!iss_write && iss_addr == f_addr) rexp[dbg_alloc_slot] <= shadow;
      end
      // gW: last write to f_addr issued to the backend
      if (dbg_mv && dbg_mr && dbg_mw && dbg_maddr == f_addr)
        gW <= dbg_mwdata;
    end
  end

  logic p_rst; always_ff @(posedge clk) p_rst <= rst_n;
  always @(posedge clk) begin
    if (rst_n && f_init) begin
      assert (mem_fa == gW);                                     // M: memory tracks last processed write
      // INV-S: with NO pending (accepted-not-applied) write to f_addr, memory
      // reflects the last write to f_addr accepted at the issue port (shadow).
      // This ties the iss-port write order (shadow) to the applied state (mem),
      // so a freshly-accepted read that captures rexp<=shadow captures mem_fa.
      begin
        logic pw; pw = 1'b0;
        for (int w = 0; w < DEPTH; w++) if (isw(w) && !dbg_issd[w]) pw = 1'b1;
        if (!pw) assert (shadow == mem_fa);                      // INV-S
      end
      for (int s = 0; s < DEPTH; s++) begin
        if (isr(s) && !dbg_done[s]) begin
          // A not-yet-applied (pending, issd=0) write is not yet in memory; an
          // applied write's value IS in memory. So a read expects: the youngest
          // PENDING older write's data, or memory if no pending older write.
          logic pend; pend = 1'b0;
          for (int w = 0; w < DEPTH; w++)
            if (isw(w) && older(w, s) && !dbg_issd[w]) pend = 1'b1;
          if (!pend) assert (rexp[s] == mem_fa);                 // R0
          for (int w = 0; w < DEPTH; w++) begin
            if (isw(w) && older(w, s) && !dbg_issd[w]) begin
              logic yg; yg = 1'b1;                               // w youngest pending older?
              for (int x = 0; x < DEPTH; x++)
                if (isw(x) && older(x, s) && !dbg_issd[x] && older(w, x)) yg = 1'b0;
              if (yg) assert (rexp[s] == wd(w));                 // R1
            end
          end
        end
        // completed read carries its expected value
        if (isr(s) && dbg_done[s]) assert (rd(s) == rexp[s]);    // I4
      end
      // INV-CQ: a pending completion in the backend FIFO that belongs to an
      // issued-not-done read to f_addr (matched by its unique tag) carries that
      // read's expected value. This links the read's captured value THROUGH the
      // FIFO to its delivery, closing I4 (and hence the property) by induction.
      for (int q = 0; q < CQ_DEPTH; q++)
        if (cq_occ(q))
          for (int s = 0; s < DEPTH; s++)
            if (isr(s) && dbg_issd[s] && !dbg_done[s] && (stag(s) == cqtag(q)))
              assert (cqdat(q) == rexp[s]);                      // INV-CQ
      // PROPERTY: a read response to f_addr returns the expected value
      if (rsp_valid && isr(dbg_rsp_slot))
        assert (rsp_rdata == rexp[dbg_rsp_slot]);
    end
    cover (rst_n && iss_valid && iss_ready);
    cover (rst_n && rsp_valid && rsp_ready);
    cover (rst_n && dbg_mv && dbg_mr);
    cover (rst_n && dut.cmp_valid);
    cover (rst_n && rsp_valid && !dbg_wr[dbg_rsp_slot]);
    cover (p_rst == 1'b0 && rst_n == 1'b1);
  end
endmodule
