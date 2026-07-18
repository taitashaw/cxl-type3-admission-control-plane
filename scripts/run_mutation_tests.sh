#!/usr/bin/env bash
# run_mutation_tests.sh — prove each protection is OBSERVABLE by the regression.
# For each mutation we disable one safety mechanism, run the relevant 4-window
# testbench under Icarus, and REQUIRE it to FAIL (mutation "killed"). A surviving
# mutation means the test suite cannot see that protection — a real gap.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
IF=rtl/interfaces/cxl_types_pkg.sv
kills=0; survivors=0

# mutate: name file 'sed-expr' tb srcs vec
mutate() {
  local name=$1 file=$2 sed=$3 tb=$4 srcs=$5 vec=$6
  local defs=${7:-"-DNWIN=4 -DHPAW=40 -DDPAW=32"}   # per-DUT compile defines
  cp -r rtl tb "$WORK"/ 2>/dev/null
  # apply mutation to the copy; FAIL LOUDLY if the pattern does not match --
  # a non-matching sed would silently leave the RTL intact and report a
  # misleading SURVIVED/killed verdict.
  cp "$WORK/$file" "$WORK/.orig" 2>/dev/null
  sed -i "$sed" "$WORK/$file"
  if cmp -s "$WORK/.orig" "$WORK/$file"; then
    echo "   [ERROR]    $name  <-- mutation sed did not match; harness bug, not a result"
    survivors=$((survivors+1)); rm -rf "$WORK/rtl" "$WORK/tb"; return
  fi
  # build/run under Icarus against the mutated copy
  ( cd "$WORK" && iverilog -g2012 -grelative-include -Irtl/interfaces $defs \
       -o mut.vvp $srcs > mut_c.log 2>&1 && vvp mut.vvp +VEC="$ROOT/$vec" > mut_run.log 2>&1 )
  if grep -q "TB_RESULT: PASS" "$WORK/mut_run.log"; then
    echo "   [SURVIVED] $name  <-- protection NOT observable (BAD)"; survivors=$((survivors+1))
  else
    local e=$(grep -oE "errors=[0-9]+" "$WORK/mut_run.log" | head -1)
    echo "   [killed]   $name  (regression fails: ${e:-build/compile error})"; kills=$((kills+1))
  fi
  rm -rf "$WORK/rtl" "$WORK/tb"
}

DEC="rtl/interfaces/cxl_types_pkg.sv rtl/core/hdm_decoder.sv rtl/core/dpa_translator.sv tb/sv/tb_hdm_decoder.sv"
CFG="rtl/interfaces/cxl_types_pkg.sv rtl/csr/hdm_config.sv tb/sv/tb_hdm_config.sv"
DVEC="tb/vectors/dec_4w_40x32.vec"
CVEC="tb/vectors/cfg_4w_40x32.vec"

echo "## Mutation tests (each must be KILLED)"
A='assign accept         = live && !unaligned && !line_oob && !ovf_raw && !oob_raw;'
# M1 fail-closed classification: single_match also true on multi-match
mutate "fail-closed multi-match" rtl/core/hdm_decoder.sv \
  's/assign single_match   = (n_match == 1);/assign single_match   = (n_match >= 1);/' \
  tb_hdm_decoder "$DEC" "$DVEC"
# M2 alignment enforcement dropped from accept
mutate "alignment rejection" rtl/core/dpa_translator.sv \
  "s/!unaligned && !line_oob/!line_oob/" \
  tb_hdm_decoder "$DEC" "$DVEC"
# M3 device-capacity (oob) check dropped from accept
mutate "device-capacity bound" rtl/core/dpa_translator.sv \
  "s/&& !ovf_raw && !oob_raw;/\&\& !ovf_raw;/" \
  tb_hdm_decoder "$DEC" "$DVEC"
# M4 full-64B-line HPA containment dropped from accept
mutate "line-containment (HPA+63)" rtl/core/dpa_translator.sv \
  "s/!line_oob && !ovf_raw/!ovf_raw/" \
  tb_hdm_decoder "$DEC" "$DVEC"
# M5 config validation disabled (everything "valid")
mutate "config validation" rtl/csr/hdm_config.sv \
  's/    req_ok = (req_reason == CFG_OK);/    req_ok = 1'"'"'b1;/' \
  tb_hdm_config "$CFG" "$CVEC"
# M5b timeout-payload legality disabled -> illegal thresholds would commit
mutate "config timeout legality" rtl/csr/hdm_config.sv \
  's/  assign to_legal = (!cfg_req_timeout_en)/  assign to_legal = 1'"'"'b1; wire _unused_to = (!cfg_req_timeout_en)/' \
  tb_hdm_config "$CFG" "$CVEC"
# M6 drain removed: commit without waiting for outstanding to reach 0
mutate "freeze/drain protocol" rtl/csr/hdm_config.sv \
  "s/if ((outstanding_cnt == '0) \&\& !alloc_fire) state <= S_COMMIT;/if (1'b1) state <= S_COMMIT;/" \
  tb_hdm_config "$CFG" "$CVEC"

# ---- M2 outstanding_tracker mutations ----
OT="rtl/core/outstanding_tracker.sv tb/sv/tb_outstanding_tracker.sv"
OVEC="tb/vectors/tracker_8d_4g.vec"
OTDEF="-DDEPTH=8 -DGENW=4 -DEPOCHW=16 -DOPW=2 -DMETAW=16 -DTSW=8"
# M7 generation check removed: a stale response would wrongly retire
mutate "tracker generation check" rtl/core/outstanding_tracker.sv \
  "s/else if (r_gen != gen\[r_slot\])  resp_class = RC_STALE_GEN;/else if (1'b0)                  resp_class = RC_STALE_GEN;/" \
  tb_outstanding_tracker "$OT" "$OVEC" "$OTDEF"
# M8 timeout aggregate broken: undercounts simultaneous timeouts
mutate "tracker timeout aggregate" rtl/core/outstanding_tracker.sv \
  "s/timeout_count <= sat_addn(timeout_count, n_new_timeout);/timeout_count <= sat_add1(timeout_count);/" \
  tb_outstanding_tracker "$OT" "$OVEC" "$OTDEF"
# M9 no-generation-bump on realloc: stale detection after reuse breaks
mutate "tracker generation bump" rtl/core/outstanding_tracker.sv \
  "s/gen\[free_slot\]      <= gen\[free_slot\] + {{(GEN_W-1){1'b0}},1'b1};/gen[free_slot]      <= gen[free_slot];/" \
  tb_outstanding_tracker "$OT" "$OVEC" "$OTDEF"
# M10 recovery contract broken: reclaim frees a NON-quarantined live slot
mutate "tracker reclaim needs quarantine" rtl/core/outstanding_tracker.sv \
  "s/else if (!timed_out\[rc_slot\])                    reclaim_class_now = RCL_NOT_QUARANTINED;/else if (1'b0)                                  reclaim_class_now = RCL_NOT_QUARANTINED;/" \
  tb_outstanding_tracker "$OT" "$OVEC" "$OTDEF"
# M11 event priority broken: a validly-retiring slot still gets timeout-marked
mutate "tracker timeout-vs-retire priority" rtl/core/outstanding_tracker.sv \
  "s/&& !(resp_retire  && r_slot  == gt\[SLOT_W-1:0\])/\&\& 1'b1/" \
  tb_outstanding_tracker "$OT" "$OVEC" "$OTDEF"
# M12 SUPERSEDED must be a NO-OP: mutate so a superseded reclaim also frees the
# slot (double-frees the same slot the response is retiring this cycle)
mutate "tracker superseded is a no-op" rtl/core/outstanding_tracker.sv \
  "s/assign reclaim_success_fire = reclaim_accept \&\& (reclaim_class_now == RCL_OK);/assign reclaim_success_fire = reclaim_accept \&\& (reclaim_class_now == RCL_OK || reclaim_class_now == RCL_SUPERSEDED);/" \
  tb_outstanding_tracker "$OT" "$OVEC" "$OTDEF"
# M13 metadata hygiene: drop the zeroing of reclaim_rsp_meta on a non-OK class
# (stale metadata from a prior successful reclaim leaks into a refusal response)
mutate "tracker non-OK meta must be zero" rtl/core/outstanding_tracker.sv \
  "s/else                             reclaim_rsp_meta <= '0;/\/\/ mutated: no zeroing/" \
  tb_outstanding_tracker "$OT" "$OVEC" "$OTDEF"
# M14 commit-sideband storage: the per-entry credit vector must be captured on
# alloc and returned on commit (drop the capture -> returned vectors are wrong)
mutate "tracker credit-vec capture on alloc" rtl/core/outstanding_tracker.sv \
  "s/credit_vec\[free_slot\] <= alloc_credit_vec;/credit_vec[free_slot] <= '0;/" \
  tb_outstanding_tracker "$OT" "$OVEC" "$OTDEF"
# M15 commit-sideband source: reclaim commit vector must be the freed slot's
# stored vector (mutate to zero -> credit return would be wrong at integration)
mutate "tracker reclaim-commit vec source" rtl/core/outstanding_tracker.sv \
  "s/assign reclaim_commit_credit_vec = reclaim_success_fire ? credit_vec\[rc_slot\] : '0;/assign reclaim_commit_credit_vec = '0;/" \
  tb_outstanding_tracker "$OT" "$OVEC" "$OTDEF"

# ---- M3 credit_manager mutations ----
CM="rtl/core/credit_manager.sv tb/sv/tb_credit_manager.sv"
CMVEC="tb/vectors/credit_2p_4c_2a.vec"
CMDEF="-DNPOOLS=2 -DCOUNTW=4 -DAMTW=2 -DRESETMAX=3"
# remove one pool from consume legality (all-or-nothing broken)
mutate "credit consume all-or-none" rtl/core/credit_manager.sv \
  "s/assign consume_legal = &c_ok_pool;/assign consume_legal = c_ok_pool[0];/" \
  tb_credit_manager "$CM" "$CMVEC" "$CMDEF"
# allow partial consume (fire even when a pool blocks)
mutate "credit no partial consume" rtl/core/credit_manager.sv \
  "s/assign consume_fire    = rst_n \&\& consume_valid \&\& consume_legal \&\& !cfg_commit_fire;/assign consume_fire    = rst_n \&\& consume_valid \&\& !cfg_commit_fire;/" \
  tb_credit_manager "$CM" "$CMVEC" "$CMDEF"
# remove return legality (illegal returns wrongly accepted)
mutate "credit return legality" rtl/core/credit_manager.sv \
  "s/assign return_legal  = &r_ok_pool;/assign return_legal  = 1'b1;/" \
  tb_credit_manager "$CM" "$CMVEC" "$CMDEF"
# same-cycle update ignores the return term (net delta wrong)
mutate "credit same-cycle net delta" rtl/core/credit_manager.sv \
  "s/if (return_accepted) next_used_w\[p\] = next_used_w\[p\] - {{(COUNT_W+1-RET_W){1'b0}}, return_amount\[p\*RET_W +: RET_W\]};/\/\/ mutated: drop return term/" \
  tb_credit_manager "$CM" "$CMVEC" "$CMDEF"
# allow configuration while credits are used (all_unused ignored)
mutate "credit cfg needs empty" rtl/core/credit_manager.sv \
  "s/config_commit \&\& frozen_and_empty \&\& all_unused \&\& cfg_representable;/config_commit \&\& frozen_and_empty \&\& cfg_representable;/" \
  tb_credit_manager "$CM" "$CMVEC" "$CMDEF"
# clamp an illegal return instead of rejecting (represent as accepting it)
mutate "credit reject not clamp" rtl/core/credit_manager.sv \
  "s/assign return_accepted = rst_n \&\& return_valid  \&\& return_legal  \&\& !cfg_commit_fire;/assign return_accepted = rst_n \&\& return_valid \&\& !cfg_commit_fire;/" \
  tb_credit_manager "$CM" "$CMVEC" "$CMDEF"
# break high-watermark update (hwm no longer tracks used)
mutate "credit high-watermark" rtl/core/credit_manager.sv \
  "s/if (next_used_w\[p\]\[COUNT_W-1:0\] > hwm_r\[p\]) hwm_r\[p\] <= next_used_w\[p\]\[COUNT_W-1:0\];/\/\/ mutated: no hwm update/" \
  tb_credit_manager "$CM" "$CMVEC" "$CMDEF"
# representability check removed (non-representable max would commit)
mutate "credit representability" rtl/core/credit_manager.sv \
  "s/assign cfg_representable = ~(|cmax_unrep);/assign cfg_representable = 1'b1;/" \
  tb_credit_manager "$CM" "$CMVEC" "$CMDEF"

# saturation replaced by wraparound -> caught by the DIAG_W=3 config (counter wraps at max)
mutate "credit diag saturation" rtl/core/credit_manager.sv \
  "s/if (&c) sat1 = c;/if (1'b0) sat1 = c;/" \
  tb_credit_manager "$CM" "tb/vectors/credit_2p_4c_2a_3d.vec" "-DNPOOLS=2 -DCOUNTW=4 -DAMTW=2 -DRESETMAX=3 -DDIAGW=3"

# ---- M4 Phase 2b admission_top integration mutations ----
ADM="rtl/core/outstanding_tracker.sv rtl/core/credit_manager.sv rtl/core/admission_top.sv tb/sv/tb_admission_top.sv"
ADMVEC="tb/vectors/adm_2p_3a_6c_8m_4d_4g.vec"
ADMDEF="-DNPOOLS=2 -DAMTW=3 -DCOUNTW=6 -DRESETMAX=8 -DDEPTH=4 -DGENW=4 -DEPOCHW=8 -DOPW=2 -DMETAW=8 -DTSW=8"
# PARTIAL ADMISSION: credit consumes even when the request was not accepted
mutate "admission partial (consume != accept)" rtl/core/admission_top.sv \
  "s/.consume_valid(req_accept), .consume_amount(req_credit_vec),/.consume_valid(req_valid), .consume_amount(req_credit_vec),/" \
  tb_admission_top "$ADM" "$ADMVEC" "$ADMDEF"
# WRONG EPOCH CAPTURE: allocate with a zero epoch instead of the active epoch
mutate "admission wrong epoch capture" rtl/core/admission_top.sv \
  "s/.alloc_req(req_accept), .alloc_epoch(active_epoch), .alloc_op(req_op),/.alloc_req(req_accept), .alloc_epoch('0), .alloc_op(req_op),/" \
  tb_admission_top "$ADM" "$ADMVEC" "$ADMDEF"
# TRUNCATED DUAL RETURN: narrow the per-pool aggregate to AMT_W (drop the +1 bit)
# -> a dual return whose per-pool sum exceeds 2^AMT_W-1 truncates
mutate "admission truncated dual return" rtl/core/admission_top.sv \
  "s/logic \[RET_W-1:0\] sum_p;/logic [AMT_W-1:0] sum_p;/" \
  tb_admission_top "$ADM" "$ADMVEC" "$ADMDEF"
# MISSING RECLAIM RETURN: reclaim commit vector never returned -> ledger leaks
mutate "admission missing reclaim return" rtl/core/admission_top.sv \
  "s/assign rcl_p = reclaim_commit_fire ? reclaim_commit_credit_vec\[gp\*AMT_W +: AMT_W\] : '0;/assign rcl_p = '0;/" \
  tb_admission_top "$ADM" "$ADMVEC" "$ADMDEF"

# ---- M4 Phase 2c control-plane (global config atomicity) mutations ----
CP="rtl/core/outstanding_tracker.sv rtl/core/credit_manager.sv rtl/core/admission_top.sv rtl/csr/config_ctrl.sv rtl/core/control_plane_top.sv tb/sv/tb_control_plane_top.sv"
CPVEC="tb/vectors/cp_2p_3a_6c_8m_4d_4g.vec"
CPDEF="-DNPOOLS=2 -DAMTW=3 -DCOUNTW=6 -DRESETMAX=8 -DDEPTH=4 -DGENW=4 -DEPOCHW=8 -DOPW=2 -DMETAW=8 -DTSW=8 -DHDMW=16 -DCAPW=16"
# commit from mutable SHADOW (live input) instead of the immutable pending snapshot
mutate "cp commit from shadow not pending" rtl/csr/config_ctrl.sv \
  "s/active_epoch <= p_epoch;/active_epoch <= cfg_epoch;/" \
  tb_control_plane_top "$CP" "$CPVEC" "$CPDEF"
# PARTIAL config update: one field (epoch) misses the shared commit
mutate "cp partial config update (epoch)" rtl/csr/config_ctrl.sv \
  "s/active_epoch <= p_epoch;/active_epoch <= active_epoch;/" \
  tb_control_plane_top "$CP" "$CPVEC" "$CPDEF"
# NOTE: "commit while occupancy/credit nonzero" is proven in FORMAL (B4 quiescence
# assert), not sim: in reachable DRAINED states conservation couples occupancy and
# credit_used, so dropping one term is masked in the differential. See
# run_formal_mutation.sh ("cp commit needs occupancy/credit zero").
# admission fires while FROZEN (req_accept_enable not gated on IDLE)
mutate "cp admission fires while frozen" rtl/csr/config_ctrl.sv \
  "s/assign req_accept_enable = rst_n \&\& (state == S_IDLE);/assign req_accept_enable = rst_n;/" \
  tb_control_plane_top "$CP" "$CPVEC" "$CPDEF"

echo "=================================================="
echo "mutations killed=$kills survived=$survivors"
[ $survivors -eq 0 ] && { echo "MUTATION TESTS: PASS (all protections observable)"; exit 0; } || { echo "MUTATION TESTS: FAIL"; exit 1; }
