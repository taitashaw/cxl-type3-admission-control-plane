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
  cp -r rtl tb "$WORK"/ 2>/dev/null
  # apply mutation to the copy
  sed -i "$sed" "$WORK/$file"
  # build/run under Icarus against the mutated copy
  local ss=""
  for s in $srcs; do ss="$ss $WORK/$s"; done
  ( cd "$WORK" && iverilog -g2012 -grelative-include -Irtl/interfaces -DNWIN=4 -DHPAW=40 -DDPAW=32 \
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
  's/shadow_valid = (shadow_reason == CFG_OK);/shadow_valid = 1'"'"'b1;/' \
  tb_hdm_config "$CFG" "$CVEC"
# M6 drain removed: commit without waiting for outstanding to reach 0
mutate "freeze/drain protocol" rtl/csr/hdm_config.sv \
  "s/if (outstanding_cnt == '0) state <= S_COMMIT;/if (1'b1) state <= S_COMMIT;/" \
  tb_hdm_config "$CFG" "$CVEC"

echo "=================================================="
echo "mutations killed=$kills survived=$survivors"
[ $survivors -eq 0 ] && { echo "MUTATION TESTS: PASS (all protections observable)"; exit 0; } || { echo "MUTATION TESTS: FAIL"; exit 1; }
