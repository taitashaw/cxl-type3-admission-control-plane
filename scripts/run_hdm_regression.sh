#!/usr/bin/env bash
# run_hdm_regression.sh — full FREE-lane M1 regression:
#   * (re)generate differential vectors from the independent Python model
#   * lint project-owned RTL (Verilator -Wall)
#   * decoder+translator differential sweep  (1/2/4/8 windows, both engines)
#   * config commit-protocol sweep           (1/2/4/8 windows, both engines)
# Fails unless EVERY (tb, config, engine) reports TB_RESULT: PASS and lint is clean.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RAW=evidence/raw; mkdir -p "$RAW" sim/icarus sim/verilator
IF=rtl/interfaces/cxl_types_pkg.sv
DEC="$IF rtl/core/hdm_decoder.sv rtl/core/dpa_translator.sv tb/sv/tb_hdm_decoder.sv"
CFG="$IF rtl/csr/hdm_config.sv tb/sv/tb_hdm_config.sv"
CONFIGS=("1 32 24" "2 40 32" "4 40 32" "8 44 36")
fail=0

echo "## regenerate vectors"
( cd tb/models && python3 gen_vectors.py ) | sed 's/^/   /'

echo "## lint (Verilator -Wall, project-owned RTL)"
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM \
  -Irtl/interfaces -Irtl/core -Irtl/csr \
  $IF rtl/csr/hdm_config.sv rtl/core/hdm_decoder.sv rtl/core/dpa_translator.sv rtl/core/hdm_decode_top.sv \
  --top-module hdm_decode_top > "$RAW/lint_core.log" 2>&1
if [ -s "$RAW/lint_core.log" ]; then echo "   LINT WARNINGS/ERRORS:"; cat "$RAW/lint_core.log" | sed 's/^/   /'; fail=1; else echo "   lint clean"; fi

run_one() { # tb_name srcs vecprefix N H D
  local tb=$1 srcs=$2 pfx=$3 N=$4 H=$5 D=$6
  local vec="tb/vectors/${pfx}_${N}w_${H}x${D}.vec"
  local tag="${tb}_${N}w_${H}x${D}"
  # Icarus
  iverilog -g2012 -grelative-include -Irtl/interfaces -DNWIN=$N -DHPAW=$H -DDPAW=$D \
    -o "sim/icarus/${tag}.vvp" $srcs > "$RAW/icarus_${tag}_c.log" 2>&1 \
    && vvp "sim/icarus/${tag}.vvp" +VEC=$vec > "$RAW/icarus_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/icarus_${tag}_run.log" && ip=PASS || { ip=FAIL; fail=1; }
  # Verilator
  rm -rf "sim/verilator/obj_${tag}"
  verilator --binary --timing -Wno-fatal -Irtl/interfaces -DNWIN=$N -DHPAW=$H -DDPAW=$D \
    --Mdir "sim/verilator/obj_${tag}" --top-module $tb $srcs > "$RAW/verilator_${tag}_b.log" 2>&1
  [ -x "sim/verilator/obj_${tag}/V${tb}" ] && "sim/verilator/obj_${tag}/V${tb}" +VEC=$vec > "$RAW/verilator_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/verilator_${tag}_run.log" && vp=PASS || { vp=FAIL; fail=1; }
  local ic=$(grep -oE "checks=[0-9]+" "$RAW/icarus_${tag}_run.log" | head -1)
  printf "   %-26s icarus=%-4s(%s) verilator=%-4s\n" "$tag" "$ip" "$ic" "$vp"
}

echo "## decoder+translator differential sweep"
for c in "${CONFIGS[@]}"; do read -r N H D <<<"$c"; run_one tb_hdm_decoder "$DEC" dec $N $H $D; done
echo "## config commit-protocol sweep"
for c in "${CONFIGS[@]}"; do read -r N H D <<<"$c"; run_one tb_hdm_config "$CFG" cfg $N $H $D; done

echo "=================================================="
[ $fail -eq 0 ] && echo "HDM REGRESSION: PASS" || echo "HDM REGRESSION: FAIL"
exit $fail
