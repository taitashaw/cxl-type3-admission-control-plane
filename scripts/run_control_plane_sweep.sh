#!/usr/bin/env bash
# run_control_plane_sweep.sh — differential regression for control_plane_top (Phase 2c)
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RAW=evidence/raw; FL=sim/filelists; mkdir -p "$RAW" sim/icarus sim/verilator
CONFIGS=("2 3 6 8 4 4" "1 2 4 3 3 2" "3 2 5 6 5 3" "2 4 7 12 2 4")
FIX="-DEPOCHW=8 -DOPW=2 -DMETAW=8 -DTSW=8 -DHDMW=16 -DCAPW=16"
fail=0
echo "## regenerate control-plane vectors"; ( cd tb/models && python3 gen_control_plane_vectors.py ) | sed 's/^/   /'
echo "## lint"; verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
  rtl/core/outstanding_tracker.sv rtl/core/credit_manager.sv rtl/core/admission_top.sv rtl/csr/config_ctrl.sv rtl/core/control_plane_top.sv \
  --top-module control_plane_top > "$RAW/lint_control_plane.log" 2>&1
lrc=$?; if [ $lrc -ne 0 ] || grep -qE "%Warning|%Error" "$RAW/lint_control_plane.log"; then echo "   LINT FAIL"; grep -E "%Warning|%Error" "$RAW/lint_control_plane.log"|sed 's/^/   /'; fail=1; else echo "   lint clean"; fi
for c in "${CONFIGS[@]}"; do
  read -r NP AW CW RM D G <<<"$c"
  vec="tb/vectors/cp_${NP}p_${AW}a_${CW}c_${RM}m_${D}d_${G}g.vec"; tag="cp_${NP}p_${AW}a_${D}d"
  DEFS="-DNPOOLS=$NP -DAMTW=$AW -DCOUNTW=$CW -DRESETMAX=$RM -DDEPTH=$D -DGENW=$G $FIX"
  iverilog -g2012 $DEFS -c "$FL/tb_control_plane_top.f" -o "sim/icarus/${tag}.vvp" >"$RAW/icarus_${tag}_c.log" 2>&1 \
    && vvp "sim/icarus/${tag}.vvp" +VEC=$vec > "$RAW/icarus_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/icarus_${tag}_run.log" && ip=PASS || { ip=FAIL; fail=1; }
  rm -rf "sim/verilator/obj_${tag}"
  verilator --binary --timing -Wno-fatal $DEFS -f "$FL/tb_control_plane_top.f" \
    --Mdir "sim/verilator/obj_${tag}" --top-module tb_control_plane_top >"$RAW/verilator_${tag}_b.log" 2>&1
  [ -x "sim/verilator/obj_${tag}/Vtb_control_plane_top" ] && "sim/verilator/obj_${tag}/Vtb_control_plane_top" +VEC=$vec > "$RAW/verilator_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/verilator_${tag}_run.log" && vp=PASS || { vp=FAIL; fail=1; }
  ck=$(grep -oE "checks=[0-9]+" "$RAW/icarus_${tag}_run.log"|head -1)
  printf "   %-16s icarus=%-4s(%s) verilator=%-4s\n" "$tag" "$ip" "$ck" "$vp"
done
echo "=================================================="
[ $fail -eq 0 ] && echo "CONTROL-PLANE SWEEP: PASS" || echo "CONTROL-PLANE SWEEP: FAIL"
exit $fail
