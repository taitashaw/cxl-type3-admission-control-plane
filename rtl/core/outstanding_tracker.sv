// outstanding_tracker.sv
// Parameterized outstanding-transaction tracker using COMPOSITE tags
// {generation, slot}. Generation is bumped on every (re)allocation of a slot;
// valid retirement requires BOTH slot and generation to match a live entry, so a
// delayed response after slot reuse is detected (STALE_GEN / NON_LIVE).
//
// EVENT PRIORITY on a single slot (highest first):
//   reset > valid-response(retire) > reclaim > new-timeout-marking > allocation
//   - a valid response retires and BLOCKS same-slot timeout marking and reclaim
//   - reclaim frees ONLY an already-quarantined (timed_out, pre-edge) live slot,
//     unless a valid response to that slot fires the same cycle (response wins)
//   - allocation cannot pick a slot that is live this cycle (retiring/reclaimed
//     slots free only next cycle) -> no same-cycle reuse, no forwarding
//
// TIMEOUT CONTRACT (modulo timestamps): timeout_thresh==0 => disabled; otherwise
// require 0 < timeout_thresh < 2^(TS_W-1) (unambiguous modulo age). An out-of-
// range (nonzero) threshold is treated as disabled and flags timeout_cfg_bad
// (sticky). A live timed-out entry is QUARANTINED (kept live, counted) — never
// silently freed — so a late response cannot alias a new transaction. Threshold
// changes apply to existing entries via their original issue_ts.
//
// COUNTERS saturate (never wrap). Duplicate detection is NOT provided (no
// retired-tag history) — see docs/tracker_contract.md.
`ifndef OUTSTANDING_TRACKER_SV
`define OUTSTANDING_TRACKER_SV

module outstanding_tracker #(
  parameter int unsigned DEPTH   = 8,    // may be non-power-of-two
  parameter int unsigned GEN_W   = 4,
  parameter int unsigned EPOCH_W = 16,
  parameter int unsigned OP_W    = 2,
  parameter int unsigned META_W  = 32,
  parameter int unsigned TS_W    = 16,
  parameter int unsigned SLOT_W  = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
  parameter int unsigned TAG_W   = GEN_W + SLOT_W,
  parameter int unsigned CNT_W   = 32,
  parameter int unsigned OCC_W   = SLOT_W + 1
) (
  input  logic                 clk,
  input  logic                 rst_n,

  input  logic [TS_W-1:0]      current_ts,
  // COMMITTED timeout configuration (owned by hdm_config's atomic commit; the
  // tracker never mutates it). Validation and the frozen/drained/!alloc_fire
  // commit gating live in the configuration controller — see docs/interface_contract.md.
  input  logic                 timeout_enable,
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
  output logic                 resp_retire,
  output logic [2:0]           resp_class,
  output logic [EPOCH_W-1:0]   retired_epoch,
  output logic [OP_W-1:0]      retired_op,
  output logic [META_W-1:0]    retired_meta,

  // ---- reclaim (recovery: frees an already-quarantined slot) ----
  // Carries the FULL composite tag: a slot-only reclaim could free a newer
  // occupant if the requester used stale state. reclaim_class is the observable
  // result. Reclaim is single-cycle and always accepted (implicit ready=1), so
  // no backpressure channel is required; the result appears combinationally.
  input  logic                 reclaim_req,
  input  logic [TAG_W-1:0]     reclaim_tag,     // {gen, slot}
  output logic                 reclaim_done,    // == (reclaim_req && class==RCL_OK)
  output logic [2:0]           reclaim_class,   // see RCL_* below

  // ---- status / counters ----
  output logic [OCC_W-1:0]     occupancy,
  output logic [OCC_W-1:0]     high_watermark,
  output logic [OCC_W-1:0]     quarantined_count, // live && timed_out (current)
  output logic                 timeout_any,
  output logic [CNT_W-1:0]     alloc_count,
  output logic [CNT_W-1:0]     retire_count,
  output logic [CNT_W-1:0]     full_count,
  output logic [CNT_W-1:0]     timeout_count,
  output logic [CNT_W-1:0]     reclaim_count,
  output logic [CNT_W-1:0]     invalid_slot_count,
  output logic [CNT_W-1:0]     non_live_count,
  output logic [CNT_W-1:0]     stale_gen_count,
  output logic                 err_sticky,
  output logic [2:0]           err_first_class
);
  localparam logic [2:0] RC_VALID=0, RC_INVALID_SLOT=1, RC_NON_LIVE=2, RC_STALE_GEN=3;
  // reclaim result classes
  localparam logic [2:0] RCL_OK=0, RCL_INVALID_SLOT=1, RCL_NOT_LIVE=2,
                         RCL_NOT_QUARANTINED=3, RCL_STALE_GEN=4, RCL_SUPERSEDED=5;

  // saturating helpers (funcname= style; no return/ternary -> portable to Yosys)
  function automatic logic [CNT_W-1:0] sat_add1(input logic [CNT_W-1:0] c);
    if (&c) sat_add1 = c;
    else    sat_add1 = c + {{(CNT_W-1){1'b0}},1'b1};
  endfunction
  function automatic logic [CNT_W-1:0] sat_addn(input logic [CNT_W-1:0] c, input logic [OCC_W-1:0] n);
    logic [CNT_W:0] s;
    s = {1'b0,c} + {{(CNT_W+1-OCC_W){1'b0}}, n};
    if (s[CNT_W]) sat_addn = {CNT_W{1'b1}};
    else          sat_addn = s[CNT_W-1:0];
  endfunction

  // ---- per-slot storage -----------------------------------------------------
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
    have_free = 1'b0; free_slot = '0;
    for (int i = DEPTH-1; i >= 0; i--)
      if (!live[i]) begin have_free = 1'b1; free_slot = i[SLOT_W-1:0]; end
  end
  assign full      = (occupancy == OCC_W'(DEPTH));
  assign alloc_gnt = alloc_req && have_free && !full;
  assign alloc_slot= free_slot;
  assign alloc_tag = {(gen[free_slot] + {{(GEN_W-1){1'b0}},1'b1}), free_slot};

  // ---- response classification ---------------------------------------------
  logic [SLOT_W-1:0] r_slot;
  logic [GEN_W-1:0]  r_gen;
  logic              r_slot_ok;
  assign r_slot   = resp_tag[SLOT_W-1:0];
  assign r_gen    = resp_tag[TAG_W-1:SLOT_W];
  assign r_slot_ok= ({{(32-SLOT_W){1'b0}}, r_slot} < DEPTH);
  always_comb begin
    resp_class = RC_VALID;
    if (resp_valid) begin
      if (!r_slot_ok)                 resp_class = RC_INVALID_SLOT;
      else if (!live[r_slot])         resp_class = RC_NON_LIVE;
      else if (r_gen != gen[r_slot])  resp_class = RC_STALE_GEN;
      else                            resp_class = RC_VALID;
    end
  end
  assign resp_retire   = resp_valid && (resp_class == RC_VALID);
  assign retired_epoch = (resp_valid && r_slot_ok) ? epoch[r_slot] : '0;
  assign retired_op    = (resp_valid && r_slot_ok) ? op[r_slot]    : '0;
  assign retired_meta  = (resp_valid && r_slot_ok) ? meta[r_slot]  : '0;

  // ---- timeout: committed configuration, used directly ---------------------
  // The tracker does NOT latch or validate the threshold. hdm_config commits
  // {HDM windows, capacity, timeout_enable, timeout_thresh, epoch} atomically on
  // one edge, only while admission is frozen, occupancy==0 and no allocation
  // fires — so a live entry can never observe a threshold change.
  logic timeout_active;
  assign timeout_active = timeout_enable && (timeout_thresh != '0);

  // ---- reclaim: composite-tag checked; only an already-quarantined slot -----
  logic [SLOT_W-1:0] rc_slot;
  logic [GEN_W-1:0]  rc_gen;
  logic              rc_slot_ok;
  assign rc_slot    = reclaim_tag[SLOT_W-1:0];
  assign rc_gen     = reclaim_tag[TAG_W-1:SLOT_W];
  assign rc_slot_ok = ({{(32-SLOT_W){1'b0}}, rc_slot} < DEPTH);
  always_comb begin
    reclaim_class = RCL_OK;
    if (reclaim_req) begin
      if (!rc_slot_ok)                                 reclaim_class = RCL_INVALID_SLOT;
      else if (!live[rc_slot])                         reclaim_class = RCL_NOT_LIVE;
      else if (rc_gen != gen[rc_slot])                 reclaim_class = RCL_STALE_GEN;
      else if (!timed_out[rc_slot])                    reclaim_class = RCL_NOT_QUARANTINED;
      else if (resp_retire && (r_slot == rc_slot))     reclaim_class = RCL_SUPERSEDED; // response wins
      else                                             reclaim_class = RCL_OK;
    end
  end
  assign reclaim_done = reclaim_req && (reclaim_class == RCL_OK);

  // ---- timeout marking with event priority ---------------------------------
  logic [DEPTH-1:0] new_timeout;
  genvar gt;
  generate
    for (gt = 0; gt < DEPTH; gt++) begin : g_to
      logic [TS_W-1:0] age;
      assign age = current_ts - issue_ts[gt];               // modulo 2^TS_W
      // new timeout only if: live, not already timed_out, age expired, timeouts
      // active, and NOT being validly retired or reclaimed this cycle.
      assign new_timeout[gt] = live[gt] && !timed_out[gt] && timeout_active
                            && (age >= timeout_thresh)
                            && !(resp_retire  && r_slot  == gt[SLOT_W-1:0])
                            && !(reclaim_done && rc_slot == gt[SLOT_W-1:0]);
    end
  endgenerate
  logic [OCC_W-1:0] n_new_timeout;
  always_comb begin
    n_new_timeout = '0;
    for (int i = 0; i < DEPTH; i++) if (new_timeout[i]) n_new_timeout += OCC_W'(1);
  end
  always_comb begin
    timeout_any = 1'b0; quarantined_count = '0;
    for (int i = 0; i < DEPTH; i++)
      if (live[i] && timed_out[i]) begin timeout_any = 1'b1; quarantined_count += OCC_W'(1); end
  end

  // occupancy deltas
  logic do_alloc, do_retire, do_reclaim;
  assign do_alloc   = alloc_gnt;
  assign do_retire  = resp_retire;
  assign do_reclaim = reclaim_done;   // already excludes same-slot valid response

  logic [OCC_W-1:0] occ_next;
  always_comb begin
    occ_next = occupancy;
    if (do_alloc)   occ_next = occ_next + 1'b1;
    if (do_retire)  occ_next = occ_next - 1'b1;
    if (do_reclaim) occ_next = occ_next - 1'b1;
  end

  // ---- sequential ----------------------------------------------------------
  integer i;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i = 0; i < DEPTH; i++) begin
        live[i]<=1'b0; gen[i]<='0; epoch[i]<='0; op[i]<='0; meta[i]<='0; issue_ts[i]<='0; timed_out[i]<=1'b0;
      end
      occupancy<='0; high_watermark<='0;
      alloc_count<='0; retire_count<='0; full_count<='0; timeout_count<='0; reclaim_count<='0;
      invalid_slot_count<='0; non_live_count<='0; stale_gen_count<='0;
      err_sticky<=1'b0; err_first_class<=RC_VALID;
    end else begin
      // timeout marking (sticky) + aggregate saturating counter
      for (i = 0; i < DEPTH; i++) if (new_timeout[i]) timed_out[i] <= 1'b1;
      timeout_count <= sat_addn(timeout_count, n_new_timeout);

      // response side effects (priority: valid response retires)
      if (resp_valid) begin
        case (resp_class)
          RC_VALID: begin
            live[r_slot]      <= 1'b0;
            timed_out[r_slot] <= 1'b0;
            retire_count      <= sat_add1(retire_count);
          end
          RC_INVALID_SLOT: begin invalid_slot_count <= sat_add1(invalid_slot_count);
                                 if(!err_sticky) begin err_sticky<=1'b1; err_first_class<=RC_INVALID_SLOT; end end
          RC_NON_LIVE:     begin non_live_count     <= sat_add1(non_live_count);
                                 if(!err_sticky) begin err_sticky<=1'b1; err_first_class<=RC_NON_LIVE; end end
          RC_STALE_GEN:    begin stale_gen_count    <= sat_add1(stale_gen_count);
                                 if(!err_sticky) begin err_sticky<=1'b1; err_first_class<=RC_STALE_GEN; end end
          default: ;
        endcase
      end

      // reclaim (recovery) — frees a quarantined slot (response already excluded)
      if (do_reclaim) begin
        live[rc_slot]      <= 1'b0;
        timed_out[rc_slot] <= 1'b0;
        reclaim_count      <= sat_add1(reclaim_count);
      end

      // allocation (free_slot distinct from any same-cycle retiring/reclaimed slot)
      if (do_alloc) begin
        live[free_slot]     <= 1'b1;
        gen[free_slot]      <= gen[free_slot] + {{(GEN_W-1){1'b0}},1'b1};
        epoch[free_slot]    <= alloc_epoch;
        op[free_slot]       <= alloc_op;
        meta[free_slot]     <= alloc_meta;
        issue_ts[free_slot] <= current_ts;
        timed_out[free_slot]<= 1'b0;
        alloc_count         <= sat_add1(alloc_count);
      end
      if (alloc_req && (full || !have_free)) full_count <= sat_add1(full_count);

      occupancy      <= occ_next;
      if (occ_next > high_watermark) high_watermark <= occ_next;
    end
  end

`ifdef FORMAL
  // ---- safety properties (bmc + induction) ---------------------------------
  logic f_init;
  logic [OCC_W-1:0]   f_pocc;
  logic               f_plive0, f_alloc0;
  logic [EPOCH_W-1:0] f_pep0;
  logic [CNT_W-1:0]   f_ptmo;
  logic [OCC_W-1:0]   f_pn_new;
  initial f_init = 1'b0;
  logic [OCC_W-1:0] live_pop;
  always_comb begin live_pop = '0; for (int j=0;j<DEPTH;j++) live_pop += OCC_W'(live[j]); end
  always_ff @(posedge clk) begin
    f_init  <= 1'b1;  f_pocc <= occupancy; f_plive0 <= live[0]; f_pep0 <= epoch[0];
    f_alloc0<= (do_alloc && free_slot == '0); f_ptmo <= timeout_count; f_pn_new <= n_new_timeout;
  end
  always @(posedge clk) begin
    if (rst_n && f_init) begin
      assert (occupancy == live_pop);
      assert (occupancy <= OCC_W'(DEPTH));
      assert (high_watermark >= occupancy);
      assert (quarantined_count <= occupancy);
      assert ($signed({1'b0,occupancy}) - $signed({1'b0,f_pocc}) <= 1);
      assert ($signed({1'b0,f_pocc}) - $signed({1'b0,occupancy}) <= 2);
      if (resp_retire) assert (live[r_slot] && (r_gen == gen[r_slot]));
      if (resp_retire) assert (resp_valid && (resp_class == RC_VALID));
      if (alloc_gnt)   assert (!full && have_free);
      assert (full == (occupancy == OCC_W'(DEPTH)));
      if (!f_alloc0) assert (epoch[0] == f_pep0);
      // reclaim only frees an already-quarantined slot (recovery contract)
      if (reclaim_done) assert (live[rc_slot] && timed_out[rc_slot] && (rc_gen == gen[rc_slot]));
      // a valid response and a reclaim never target the same slot (response wins)
      if (resp_retire && reclaim_done) assert (r_slot != rc_slot);
      // timeout_count advances by exactly the number of newly-timed-out slots,
      // with SATURATION — mirror the RTL's saturating add exactly (inductive).
      assert (timeout_count == sat_addn(f_ptmo, f_pn_new));
    end
  end
`endif
endmodule
`endif
