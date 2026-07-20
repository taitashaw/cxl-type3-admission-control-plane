#!/usr/bin/env bash
# run_scheduler_sweep.sh — differential regression for rw_scheduler (M5)
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RAW=evidence/raw; FL=sim/filelists; mkdir -p "$RAW" sim/icarus sim/verilator
CONFIGS=("6 2 8 4" "5 1 4 2" "6 2 8 3" "7 3 8 5")
fail=0
echo "## regenerate scheduler vectors"; ( cd tb/models && python3 gen_scheduler_vectors.py ) | sed 's/^/   /'
echo "## lint"; verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
  rtl/core/rw_scheduler.sv --top-module rw_scheduler > "$RAW/lint_scheduler.log" 2>&1
lrc=$?; if [ $lrc -ne 0 ] || grep -qE "%Warning|%Error" "$RAW/lint_scheduler.log"; then echo "   LINT FAIL"; grep -E "%Warning|%Error" "$RAW/lint_scheduler.log"|sed 's/^/   /'; fail=1; else echo "   lint clean"; fi
for c in "${CONFIGS[@]}"; do
  read -r TW AW DW D <<<"$c"
  vec="tb/vectors/sch_${TW}t_${AW}a_${DW}d_${D}n.vec"; tag="sch_${TW}t_${AW}a_${D}n"
  DEFS="-DTAGW=$TW -DADDRW=$AW -DDATAW=$DW -DDEPTH=$D"
  iverilog -g2012 $DEFS -c "$FL/tb_rw_scheduler.f" -o "sim/icarus/${tag}.vvp" >"$RAW/icarus_${tag}_c.log" 2>&1 \
    && vvp "sim/icarus/${tag}.vvp" +VEC=$vec > "$RAW/icarus_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/icarus_${tag}_run.log" && ip=PASS || { ip=FAIL; fail=1; }
  rm -rf "sim/verilator/obj_${tag}"
  verilator --binary --timing -Wno-fatal $DEFS -f "$FL/tb_rw_scheduler.f" \
    --Mdir "sim/verilator/obj_${tag}" --top-module tb_rw_scheduler >"$RAW/verilator_${tag}_b.log" 2>&1
  [ -x "sim/verilator/obj_${tag}/Vtb_rw_scheduler" ] && "sim/verilator/obj_${tag}/Vtb_rw_scheduler" +VEC=$vec > "$RAW/verilator_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/verilator_${tag}_run.log" && vp=PASS || { vp=FAIL; fail=1; }
  ck=$(grep -oE "checks=[0-9]+" "$RAW/icarus_${tag}_run.log"|head -1)
  printf "   %-14s icarus=%-4s(%s) verilator=%-4s\n" "$tag" "$ip" "$ck" "$vp"
done
echo "=================================================="
[ $fail -eq 0 ] && echo "SCHEDULER SWEEP: PASS" || echo "SCHEDULER SWEEP: FAIL"
exit $fail
