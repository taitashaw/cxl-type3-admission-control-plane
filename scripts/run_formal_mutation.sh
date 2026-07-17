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
echo "=================================================="
echo "formal mutations killed=$kills survived=$survivors"
[ $survivors -eq 0 ] && { echo "FORMAL MUTATION: PASS (proofs are non-vacuous)"; exit 0; } || { echo "FORMAL MUTATION: FAIL"; exit 1; }
