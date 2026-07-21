#!/usr/bin/env bash
# run_formal_mutation.sh — prove the FORMAL properties are non-vacuous by breaking
# a protection in the RTL and confirming the relevant SymbiYosys proof now FAILS
# (finds a counterexample). A mutation that still PASSES formal means the proof
# does not actually constrain that behavior.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
ENV=tools/oss-cad-suite/environment
[ -f "$ENV" ] || { echo "FORMAL-MUT: BLOCKED (OSS CAD Suite absent)"; exit 3; }
source "$ENV"
kills=0; survivors=0

# name sbyfile file 'sed' task
fmut() {
  local name=$1 sby=$2 file=$3 sed=$4 task=$5
  local W; W=$(mktemp -d)
  cp -r rtl formal "$W"/
  sed -i "$sed" "$W/$file"
  ( cd "$W" && sby -f "$sby" "$task" > mut.log 2>&1 )
  if grep -q "DONE (FAIL" "$W/mut.log" || grep -q "Assert failed" "$W/mut.log"; then
    echo "   [killed]   $name  (formal $task finds counterexample)"; kills=$((kills+1))
  else
    echo "   [SURVIVED] $name  <-- proof did NOT fail (vacuous?)"; survivors=$((survivors+1))
  fi
  rm -rf "$W"
}

echo "## Formal mutation tests (each proof must FAIL when its protection is broken)"
# fail-closed: single_match on multi-match -> p_onehot / p_class must fail
fmut "decode: fail-closed one-hot" formal/decode.sby rtl/core/hdm_decoder.sv \
  's/assign single_match   = (n_match == 1);/assign single_match   = (n_match >= 1);/' bmc
# line containment: drop !line_oob from accept -> p_line_in must fail
fmut "decode: line containment" formal/decode.sby rtl/core/dpa_translator.sv \
  "s/!unaligned && !line_oob/!unaligned/" bmc
# capacity: drop !oob_raw from accept -> p_bounds must fail
fmut "decode: capacity bound" formal/decode.sby rtl/core/dpa_translator.sv \
  "s/&& !ovf_raw && !oob_raw;/\&\& !ovf_raw;/" bmc
# commit atomicity/snapshot: commit from shadow instead of pending -> assert must fail
fmut "config: snapshot commit" formal/config.sby rtl/csr/hdm_config.sv \
  's/act_en\[k\]   <= pend_en\[k\];/act_en[k]   <= sh_en[k];/' bmc
# drain: commit without waiting for outstanding==0 -> drain assert must fail
fmut "config: drain-before-commit" formal/config.sby rtl/csr/hdm_config.sv \
  "s/if ((outstanding_cnt == '0) \&\& !alloc_fire) state <= S_COMMIT;/if (1'b1) state <= S_COMMIT;/" bmc

# tracker: aggregate timeout counter -> per-slot +1 (undercounts simultaneous timeouts)
fmut "tracker: timeout aggregate" formal/tracker.sby rtl/core/outstanding_tracker.sv \
  "s/timeout_count <= sat_addn(timeout_count, n_new_timeout);/timeout_count <= sat_add1(timeout_count);/" bmc
# tracker: retire without generation match -> stale response wrongly retires
fmut "tracker: generation check" formal/tracker.sby rtl/core/outstanding_tracker.sv \
  "s/else if (r_gen != gen\[r_slot\])  resp_class = RC_STALE_GEN;/else if (1'b0)                  resp_class = RC_STALE_GEN;/" bmc
# tracker: SUPERSEDED must be a no-op -> mutate it to also free the slot, so a
# reclaim and a valid response free the SAME slot (r_slot==rc_slot assert fails)
fmut "tracker: superseded no-op" formal/tracker.sby rtl/core/outstanding_tracker.sv \
  "s/assign reclaim_success_fire = reclaim_accept \&\& (reclaim_class_now == RCL_OK);/assign reclaim_success_fire = reclaim_accept \&\& (reclaim_class_now == RCL_OK || reclaim_class_now == RCL_SUPERSEDED);/" bmc
# credit: config commits while pools are in use -> used<=max invariant breaks
fmut "credit: cfg needs empty" formal/credit.sby rtl/core/credit_manager.sv \
  "s/config_commit \&\& frozen_and_empty \&\& all_unused \&\& cfg_representable;/config_commit \&\& frozen_and_empty \&\& cfg_representable;/" bmc
# credit: drop return term in net delta -> ledger delta property fails
fmut "credit: net delta" formal/credit.sby rtl/core/credit_manager.sv \
  "s/if (return_accepted) next_used_w\[p\] = next_used_w\[p\] - {{(COUNT_W+1-RET_W){1'b0}}, return_amount\[p\*RET_W +: RET_W\]};/\/\/ mutated/" bmc
# credit: config does not block consume -> commit-blocks-both property fails
fmut "credit: cfg blocks consume" formal/credit.sby rtl/core/credit_manager.sv \
  "s/assign consume_fire    = rst_n \&\& consume_valid \&\& consume_legal \&\& !cfg_commit_fire;/assign consume_fire    = rst_n \&\& consume_valid \&\& consume_legal;/" bmc

# credit: saturation -> wrap breaks the no-wrap (monotone) diagnostic assert
fmut "credit: diag saturation" formal/credit.sby rtl/core/credit_manager.sv \
  "s/if (&c) sat1 = c;/if (1'b0) sat1 = c;/" bmc

# ---- M4 Phase 2b admission integration formal mutations (base: admission_mut.sby,
# RESET_MAX>2^AMT_W-1 so dual-return truncation is reachable) ----
AMB=formal/admission_mut.sby; AMT=rtl/core/admission_top.sv
# partial admission: consume without accept -> all-fire + conservation fail
fmut "admission: partial admission" "$AMB" "$AMT" \
  "s/.consume_valid(req_accept), .consume_amount(req_credit_vec),/.consume_valid(req_valid), .consume_amount(req_credit_vec),/" bmc
# missing reclaim return: reclaim frees a slot but returns no credit -> conservation
fmut "admission: missing reclaim return" "$AMB" "$AMT" \
  "s/assign rcl_p = reclaim_commit_fire ? reclaim_commit_credit_vec\[gp\*AMT_W +: AMT_W\] : '0;/assign rcl_p = '0;/" bmc
# narrowed dual-return accumulator: modulo-wrap could hide a dual return -> conservation
fmut "admission: narrowed dual-return accumulator" "$AMB" "$AMT" \
  "s/logic \[RET_W-1:0\] sum_p;/logic [AMT_W-1:0] sum_p;/" bmc
# wrong pool slice: every pool returns pool-0's credit -> conservation fails for p>0
fmut "admission: wrong pool slice" "$AMB" "$AMT" \
  "s/assign ret_p = retire_commit_fire  ? retire_commit_credit_vec \[gp\*AMT_W +: AMT_W\] : '0;/assign ret_p = retire_commit_fire  ? retire_commit_credit_vec [0 +: AMT_W] : '0;/" bmc
# wrong epoch capture: allocate with epoch 0 -> epoch-capture assert fails
fmut "admission: wrong epoch capture" "$AMB" "$AMT" \
  "s/.alloc_req(req_accept), .alloc_epoch(active_epoch), .alloc_op(req_op),/.alloc_req(req_accept), .alloc_epoch('0), .alloc_op(req_op),/" bmc
# timeout frees a credit-bearing slot -> live_sum drops with no return -> conservation
fmut "admission: timeout must not free credit" "$AMB" rtl/core/outstanding_tracker.sv \
  "s/for (i = 0; i < DEPTH; i++) if (new_timeout\[i\]) timed_out\[i\] <= 1'b1;/for (i = 0; i < DEPTH; i++) if (new_timeout[i]) begin timed_out[i] <= 1'b1; live[i] <= 1'b0; end/" bmc

# ---- M4 Phase 2c control-plane global-atomicity formal mutations ----
CPB=formal/control_plane.sby
# commit from mutable shadow -> "field == $past(pending)" atomicity assert fails
fmut "cp commit from shadow not pending" "$CPB" rtl/csr/config_ctrl.sv \
  "s/active_epoch <= p_epoch;/active_epoch <= cfg_epoch;/" bmc
# a field misses the shared commit (partial update) -> atomicity assert fails
fmut "cp partial config update" "$CPB" rtl/csr/config_ctrl.sv \
  "s/active_epoch <= p_epoch;/active_epoch <= active_epoch;/" bmc
# commit while occupancy nonzero -> no-live-entry-crosses-commit / shared-commit fails
fmut "cp commit needs occupancy zero" "$CPB" rtl/csr/config_ctrl.sv \
  "s/assign quiescent = (adm_occupancy == '0) \&\& (adm_quarantined == '0)/assign quiescent = (1'b1) \&\& (adm_quarantined == '0)/" bmc
# commit while the ISSUE BUFFER is occupied (drop the issue-empty quiescence term)
# -> commit-quiescence assert (!issue_valid) fails
fmut "cp commit while issue occupied" "$CPB" rtl/csr/config_ctrl.sv \
  "s/&& adm_credit_used_zero && !adm_issue_valid && !adm_req_accept/\&\& adm_credit_used_zero \&\& 1'b1 \&\& !adm_req_accept/" bmc
# admission not frozen while (re)configuring -> freeze assert fails
fmut "cp admission fires while frozen" "$CPB" rtl/csr/config_ctrl.sv \
  "s/assign req_accept_enable = rst_n \&\& (state == S_IDLE);/assign req_accept_enable = rst_n;/" bmc

# ---- M5 rw_scheduler formal mutations ----
SCHB=formal/scheduler.sby
# drop hazard interlock -> per-address ordering assert fails
fmut "sched drop hazard interlock" "$SCHB" rtl/core/rw_scheduler.sv \
  "s/if (vld\[j\] \&\& older\[j\]\[i\] \&\& (adr\[j\] == adr\[i\]) \&\& !done\[j\]) blk = 1'b1;/if (1'b0) blk = 1'b1;/" bmc
# respond before completion -> rsp_valid => done assert fails
fmut "sched respond before done" "$SCHB" rtl/core/rw_scheduler.sv \
  "s/for (int i = DEPTH-1; i >= 0; i--) if (vld\[i\] \&\& done\[i\]) begin rsp_valid = 1'b1; rsp_sel = i\[IDX_W-1:0\]; end/for (int i = DEPTH-1; i >= 0; i--) if (vld[i]) begin rsp_valid = 1'b1; rsp_sel = i[IDX_W-1:0]; end/" bmc
# age not established on accept -> age strict-total-order assert fails
fmut "sched age not set on accept" "$SCHB" rtl/core/rw_scheduler.sv \
  "s/if (k\[IDX_W-1:0\] != free_slot) older\[k\]\[free_slot\] <= vld\[k\];/if (k[IDX_W-1:0] != free_slot) older[k][free_slot] <= 1'b0;/" bmc

# ---- M6 mem_backend formal mutations ----
MEMB=formal/mem_backend.sby
# req_ready ignores full -> cnt bound / req_ready==!full assert fails
fmut "mem req_ready ignores full" "$MEMB" rtl/core/mem_backend.sv \
  "s/assign req_ready = rst_n \&\& (cnt != CCNT_W'(CQ_DEPTH));/assign req_ready = rst_n;/" bmc
# a write is not stored -> write-reflected-in-array assert fails
fmut "mem write not stored" "$MEMB" rtl/core/mem_backend.sv \
  "s/if (req_write) mem\[req_addr\] <= req_wdata;/if (1'b0) mem[req_addr] <= req_wdata;/" bmc
# pointer never wraps -> head/tail range assert fails
fmut "mem pointer no wrap" "$MEMB" rtl/core/mem_backend.sv \
  "s/else                          pinc = p + CPTR_W'(1);/else                          pinc = p + CPTR_W'(1); \/\/ ok/;s/if (p == CPTR_W'(CQ_DEPTH-1)) pinc = '0;/if (1'b0) pinc = '0;/" bmc

# ---- M6 mem_subsys END-TO-END read-after-write formal mutations (these break the
# integration's unique property; the component proofs alone do NOT catch them) ----
MSYB=formal/mem_subsys.sby
# read returns 0 instead of the captured memory value -> end-to-end rsp_rdata wrong.
# NOTE: the standalone mem_backend proof has no read-after-write reference and does
# NOT catch this; only the mem_subsys end-to-end induction property does.
fmut "memsubsys read returns zero" "$MSYB" rtl/core/mem_backend.sv \
  "s/assign rd_val = mem\[req_addr\];/assign rd_val = '0;/" bmc
# scheduler completion latches 0 instead of the returned data -> response wrong
fmut "memsubsys completion drops data" "$MSYB" rtl/core/rw_scheduler.sv \
  "s/done\[k\]<=1'b1; rdat\[k\]<=mc_rdata;/done[k]<=1'b1; rdat[k]<='0;/" bmc
# drop the same-address hazard interlock -> a read can reorder ahead of an older
# same-address write and return a STALE value -> end-to-end property fails
fmut "memsubsys drop hazard interlock" "$MSYB" rtl/core/rw_scheduler.sv \
  "s/if (vld\[j\] \&\& older\[j\]\[i\] \&\& (adr\[j\] == adr\[i\]) \&\& !done\[j\]) blk = 1'b1;/if (1'b0) blk = 1'b1;/" bmc

echo "=================================================="
echo "formal mutations killed=$kills survived=$survivors"
[ $survivors -eq 0 ] && { echo "FORMAL MUTATION: PASS (proofs are non-vacuous)"; exit 0; } || { echo "FORMAL MUTATION: FAIL"; exit 1; }
