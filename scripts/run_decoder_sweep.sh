#!/usr/bin/env bash
# run_decoder_sweep.sh — parameter-sweep differential regression for the decoder
# + translator across N_WIN in {1,2,4,8} and reduced/production widths, on BOTH
# Icarus and Verilator. Vectors come from the independent Python model.
# Fails unless EVERY (config, engine) pair reports TB_RESULT: PASS.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RAW=evidence/raw; mkdir -p "$RAW" sim/icarus sim/verilator
SRCS="rtl/interfaces/cxl_types_pkg.sv rtl/core/hdm_decoder.sv rtl/core/dpa_translator.sv tb/sv/tb_hdm_decoder.sv"

# N H D
CONFIGS=("1 32 24" "2 40 32" "4 40 32" "8 44 36")
fail=0

for c in "${CONFIGS[@]}"; do
  read -r N H D <<<"$c"
  vec="tb/vectors/dec_${N}w_${H}x${D}.vec"
  tag="dec_${N}w_${H}x${D}"
  echo "===== $tag ====="

  # Icarus
  if iverilog -g2012 -grelative-include -Irtl/interfaces -DNWIN=$N -DHPAW=$H -DDPAW=$D \
       -o "sim/icarus/${tag}.vvp" $SRCS > "$RAW/icarus_${tag}_compile.log" 2>&1; then
    vvp "sim/icarus/${tag}.vvp" +VEC=$vec > "$RAW/icarus_${tag}_run.log" 2>&1
  fi
  ir=$(grep -E "checks=|TB_RESULT" "$RAW/icarus_${tag}_run.log" | tr '\n' ' ')
  grep -q "TB_RESULT: PASS" "$RAW/icarus_${tag}_run.log" || fail=1
  echo "  icarus   : $ir"

  # Verilator (single-threaded build to avoid 5.020 -j0 exit abort)
  rm -rf "sim/verilator/obj_${tag}"
  if verilator --binary --timing -Wno-fatal -Irtl/interfaces -DNWIN=$N -DHPAW=$H -DDPAW=$D \
       --Mdir "sim/verilator/obj_${tag}" --top-module tb_hdm_decoder $SRCS \
       > "$RAW/verilator_${tag}_build.log" 2>&1; then
    "./sim/verilator/obj_${tag}/Vtb_hdm_decoder" +VEC=$vec > "$RAW/verilator_${tag}_run.log" 2>&1
  fi
  vr=$(grep -E "checks=|TB_RESULT" "$RAW/verilator_${tag}_run.log" | tr '\n' ' ')
  grep -q "TB_RESULT: PASS" "$RAW/verilator_${tag}_run.log" || fail=1
  echo "  verilator: $vr"
done

echo "=================================="
[ $fail -eq 0 ] && echo "DECODER SWEEP: PASS (all configs, both engines)" || echo "DECODER SWEEP: FAIL"
exit $fail
