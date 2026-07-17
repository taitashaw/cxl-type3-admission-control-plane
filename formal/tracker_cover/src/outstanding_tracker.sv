// outstanding_tracker.sv
// Parameterized outstanding-transaction tracker using COMPOSITE tags
// {generation, slot}. A bare slot number is not returned as the tag: after a
// slot is retired and reused, a delayed response for the previous occupant would
// be indistinguishable from the new transaction. The generation, bumped on every
// (re)allocation of a slot, makes a stale response detectable — valid retirement
// requires BOTH slot and generation to match a live entry.
//
// Timeout policy: QUARANTINE + REPORT. A timed-out entry stays LIVE (its slot is
// not silently freed, so a late response cannot alias a new transaction) and is
// flagged sticky + counted. An explicit reclaim frees a slot; the next
// allocation bumps its generation, so any later response to it is STALE/NON-LIVE.
//
// Duplicate detection caveat: once an entry is retired its slot may be reused, so
// a duplicate late response is classified NON_LIVE (or STALE_GEN after realloc) —
// not a distinct DUPLICATE — because no retired-tag history is kept. See docs.
`ifndef OUTSTANDING_TRACKER_SV
`define OUTSTANDING_TRACKER_SV

module outstanding_tracker #(
  parameter int unsigned DEPTH   = 8,    // may be non-power-of-two
  parameter int unsigned GEN_W   = 4,
  parameter int unsigned EPOCH_W = 16,
  parameter int unsigned OP_W    = 2,
  parameter int unsigned META_W  = 32,
  parameter int unsigned TS_W    = 16,
  // derived; do not override
  parameter int unsigned SLOT_W  = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
  parameter int unsigned TAG_W   = GEN_W + SLOT_W,
  parameter int unsigned CNT_W   = 32,
  parameter int unsigned OCC_W   = SLOT_W + 1
) (
  input  logic                 clk,
  input  logic                 rst_n,

  // global timestamp + timeout threshold (must be < 2^(TS_W-1) for modulo age)
  input  logic [TS_W-1:0]      current_ts,
  input  logic [TS_W-1:0]      timeout_thresh,

  // ---- allocation ----
  input  logic                 alloc_req,
  input  logic [EPOCH_W-1:0]   alloc_epoch,
  input  logic [OP_W-1:0]      alloc_op,
  input  logic [META_W-1:0]    alloc_meta,
  output logic                 alloc_gnt,
  output logic [TAG_W-1:0]     alloc_tag,     // {gen, slot}
  output logic [SLOT_W-1:0]    alloc_slot,
  output logic                 full,

  // ---- retirement (response) ----
  input  logic                 resp_valid,
  input  logic [TAG_W-1:0]     resp_tag,      // {gen, slot}
  output logic                 resp_retire,   // a VALID retirement happened
  output logic [2:0]           resp_class,    // see RC_* below
  output logic [EPOCH_W-1:0]   retired_epoch,
  output logic [OP_W-1:0]      retired_op,
  output logic [META_W-1:0]    retired_meta,

  // ---- reclaim (force-free a slot, e.g. a quarantined/timed-out one) ----
  input  logic                 reclaim_req,
  input  logic [SLOT_W-1:0]    reclaim_slot,
  output logic                 reclaim_done,

  // ---- status / counters ----
  output logic [OCC_W-1:0]     occupancy,
  output logic [OCC_W-1:0]     high_watermark,
  output logic                 timeout_any,     // any live entry currently timed out
  output logic [CNT_W-1:0]     alloc_count,
  output logic [CNT_W-1:0]     retire_count,
  output logic [CNT_W-1:0]     full_count,
  output logic [CNT_W-1:0]     timeout_count,
  output logic [CNT_W-1:0]     invalid_slot_count,
  output logic [CNT_W-1:0]     non_live_count,
  output logic [CNT_W-1:0]     stale_gen_count,
  output logic                 err_sticky,      // first-error sticky
  output logic [2:0]           err_first_class  // class of the first error captured
);
  // response classes
  localparam logic [2:0] RC_VALID=0, RC_INVALID_SLOT=1, RC_NON_LIVE=2, RC_STALE_GEN=3;

  // ---- per-slot storage (register-file style) ------------------------------
  logic                live     [DEPTH];
  logic [GEN_W-1:0]    gen      [DEPTH];
  logic [EPOCH_W-1:0]  epoch    [DEPTH];
  logic [OP_W-1:0]     op       [DEPTH];
  logic [META_W-1:0]   meta     [DEPTH];
  logic [TS_W-1:0]     issue_ts [DEPTH];
  logic                timed_out[DEPTH];

  // ---- free-slot selection: lowest-index free slot -------------------------
  logic [SLOT_W-1:0] free_slot;
  logic              have_free;
  always_comb begin
    have_free = 1'b0;
    free_slot = '0;
    for (int i = DEPTH-1; i >= 0; i--)
      if (!live[i]) begin have_free = 1'b1; free_slot = i[SLOT_W-1:0]; end
  end
  assign full      = (occupancy == OCC_W'(DEPTH));
  assign alloc_gnt = alloc_req && have_free && !full;
  assign alloc_slot= free_slot;
  // returned tag carries the NEW (post-bump) generation
  assign alloc_tag = {(gen[free_slot] + {{(GEN_W-1){1'b0}},1'b1}), free_slot};

  // ---- response classification (combinational) -----------------------------
  logic [SLOT_W-1:0] r_slot;
  logic [GEN_W-1:0]  r_gen;
  logic              r_slot_ok;
  assign r_slot   = resp_tag[SLOT_W-1:0];
  assign r_gen    = resp_tag[TAG_W-1:SLOT_W];
  // 32-bit-extended compare is correct for both power-of-two and non-power-of-two
  // DEPTH (a narrow SLOT_W'(DEPTH) cast would wrap to 0 when DEPTH==2^SLOT_W).
  assign r_slot_ok= ({{(32-SLOT_W){1'b0}}, r_slot} < DEPTH);

  always_comb begin
    resp_class = RC_VALID;
    if (resp_valid) begin
      if (!r_slot_ok)                     resp_class = RC_INVALID_SLOT;
      else if (!live[r_slot])             resp_class = RC_NON_LIVE;
      else if (r_gen != gen[r_slot])      resp_class = RC_STALE_GEN;
      else                                resp_class = RC_VALID;
    end
  end
  assign resp_retire   = resp_valid && (resp_class == RC_VALID);
  // metadata read BEFORE any clear; meaningful only on a response with an
  // in-range slot (consumers use it only when resp_retire=1).
  assign retired_epoch = (resp_valid && r_slot_ok) ? epoch[r_slot] : '0;
  assign retired_op    = (resp_valid && r_slot_ok) ? op[r_slot]    : '0;
  assign retired_meta  = (resp_valid && r_slot_ok) ? meta[r_slot]  : '0;

  // ---- reclaim -------------------------------------------------------------
  assign reclaim_done = reclaim_req && ({{(32-SLOT_W){1'b0}},reclaim_slot} < DEPTH) && live[reclaim_slot];

  // ---- timeout (modulo-age; report + quarantine) ---------------------------
  logic [DEPTH-1:0] timeout_now;
  genvar gt;
  generate
    for (gt = 0; gt < DEPTH; gt++) begin : g_to
      logic [TS_W-1:0] age;
      assign age = current_ts - issue_ts[gt];          // modulo 2^TS_W
      assign timeout_now[gt] = live[gt] && (age >= timeout_thresh);
    end
  endgenerate
  always_comb begin
    timeout_any = 1'b0;
    for (int i = 0; i < DEPTH; i++) if (live[i] && timed_out[i]) timeout_any = 1'b1;
  end
  // Count of slots newly timing out THIS cycle (aggregate so simultaneous
  // timeouts all count — a per-slot `cnt<=cnt+1` in a loop would only add 1,
  // since every nonblocking assign reads the same pre-edge value).
  logic [OCC_W-1:0] n_new_timeout;
  always_comb begin
    n_new_timeout = '0;
    for (int i = 0; i < DEPTH; i++)
      if (timeout_now[i] && !timed_out[i]) n_new_timeout += OCC_W'(1);
  end

  // occupancy delta components
  logic do_alloc, do_retire, do_reclaim;
  assign do_alloc   = alloc_gnt;
  assign do_retire  = resp_retire;
  assign do_reclaim = reclaim_done && !(resp_retire && (r_slot == reclaim_slot)); // don't double-free same slot

  // ---- sequential ----------------------------------------------------------
  integer i;
  logic [OCC_W-1:0] occ_next;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i = 0; i < DEPTH; i++) begin
        live[i]<=1'b0; gen[i]<='0; epoch[i]<='0; op[i]<='0; meta[i]<='0; issue_ts[i]<='0; timed_out[i]<=1'b0;
      end
      occupancy<='0; high_watermark<='0;
      alloc_count<='0; retire_count<='0; full_count<='0; timeout_count<='0;
      invalid_slot_count<='0; non_live_count<='0; stale_gen_count<='0;
      err_sticky<=1'b0; err_first_class<=RC_VALID;
    end else begin
      // timeout marking (sticky per slot) + aggregate counter. Timeout has its
      // own reporting (timeout_any / timeout_count); it does NOT touch the
      // response-error sticky (err_sticky), which captures the first bad response.
      for (i = 0; i < DEPTH; i++)
        if (timeout_now[i] && !timed_out[i]) timed_out[i] <= 1'b1;
      timeout_count <= timeout_count + {{(CNT_W-OCC_W){1'b0}}, n_new_timeout};

      // retirement / response classification side effects
      if (resp_valid) begin
        case (resp_class)
          RC_VALID: begin
            live[r_slot]      <= 1'b0;
            timed_out[r_slot] <= 1'b0;
            retire_count      <= retire_count + 1'b1;
          end
          RC_INVALID_SLOT: begin invalid_slot_count <= invalid_slot_count + 1'b1;
                                 if(!err_sticky) begin err_sticky<=1'b1; err_first_class<=RC_INVALID_SLOT; end end
          RC_NON_LIVE:     begin non_live_count     <= non_live_count + 1'b1;
                                 if(!err_sticky) begin err_sticky<=1'b1; err_first_class<=RC_NON_LIVE; end end
          RC_STALE_GEN:    begin stale_gen_count    <= stale_gen_count + 1'b1;
                                 if(!err_sticky) begin err_sticky<=1'b1; err_first_class<=RC_STALE_GEN; end end
          default: ;
        endcase
      end

      // reclaim (free a slot; generation bumped on next allocation)
      if (do_reclaim) begin
        live[reclaim_slot]      <= 1'b0;
        timed_out[reclaim_slot] <= 1'b0;
      end

      // allocation (free_slot is guaranteed != any same-cycle retiring/reclaimed
      // slot because those are still live this cycle)
      if (do_alloc) begin
        live[free_slot]     <= 1'b1;
        gen[free_slot]      <= gen[free_slot] + {{(GEN_W-1){1'b0}},1'b1};
        epoch[free_slot]    <= alloc_epoch;
        op[free_slot]       <= alloc_op;
        meta[free_slot]     <= alloc_meta;
        issue_ts[free_slot] <= current_ts;
        timed_out[free_slot]<= 1'b0;
        alloc_count         <= alloc_count + 1'b1;
      end
      if (alloc_req && (full || !have_free)) full_count <= full_count + 1'b1;

      // occupancy update (+alloc, -retire, -reclaim)
      occupancy      <= occ_next;
      if (occ_next > high_watermark) high_watermark <= occ_next;
    end
  end

  // occupancy next (combinational, signed-safe)
  always_comb begin
    occ_next = occupancy;
    if (do_alloc)   occ_next = occ_next + 1'b1;
    if (do_retire)  occ_next = occ_next - 1'b1;
    if (do_reclaim) occ_next = occ_next - 1'b1;
  end

`ifdef FORMAL
  // ---- safety properties (bounded + induction) -----------------------------
  logic f_init;
  logic [OCC_W-1:0]   f_pocc;
  logic               f_plive0, f_alloc0;
  logic [EPOCH_W-1:0] f_pep0;
  logic [CNT_W-1:0]   f_ptmo;
  logic [OCC_W-1:0]   f_pn_new;
  initial f_init = 1'b0;
  // popcount of live
  logic [OCC_W-1:0] live_pop;
  always_comb begin live_pop = '0; for (int j=0;j<DEPTH;j++) live_pop += OCC_W'(live[j]); end
  always_ff @(posedge clk) begin
    f_init  <= 1'b1;
    f_pocc  <= occupancy;
    f_plive0<= live[0];
    f_pep0  <= epoch[0];
    f_alloc0<= (do_alloc && free_slot == '0);   // an alloc targeted slot 0 this edge
    f_ptmo  <= timeout_count;
    f_pn_new<= n_new_timeout;
  end

  always @(posedge clk) begin
    if (rst_n && f_init) begin
      assert (occupancy == live_pop);              // occupancy == popcount(live)
      assert (occupancy <= OCC_W'(DEPTH));          // never exceeds DEPTH
      assert (high_watermark >= occupancy);         // watermark >= occupancy
      // occupancy moves by at most +1 / -2 per cycle (alloc + retire + reclaim)
      assert ($signed({1'b0,occupancy}) - $signed({1'b0,f_pocc}) <= 1);
      assert ($signed({1'b0,f_pocc}) - $signed({1'b0,occupancy}) <= 2);
      // a VALID retire requires a live entry with matching generation
      if (resp_retire) assert (live[r_slot] && (r_gen == gen[r_slot]));
      // retire implies a response; only VALID responses retire
      if (resp_retire) assert (resp_valid && (resp_class == RC_VALID));
      // a grant implies a free slot existed (not full)
      if (alloc_gnt) assert (!full && have_free);
      // full <-> occupancy==DEPTH
      assert (full == (occupancy == OCC_W'(DEPTH)));
      // live entry metadata is STABLE until reallocation (slot-0 witness):
      // epoch[0] can only change on an allocation that targeted slot 0.
      if (!f_alloc0) assert (epoch[0] == f_pep0);
      // timeout_count advances by EXACTLY the number of slots that newly timed
      // out (aggregate, not +1) — catches simultaneous-timeout undercounting.
      assert (timeout_count == (f_ptmo + {{(CNT_W-OCC_W){1'b0}}, f_pn_new}));
    end
  end
`endif
endmodule
`endif
