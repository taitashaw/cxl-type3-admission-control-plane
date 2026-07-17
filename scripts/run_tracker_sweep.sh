#!/usr/bin/env bash
# run_tracker_sweep.sh — differential regression for outstanding_tracker across
# DEPTH in {1,2,3,4,7,8,16} (incl. non-power-of-two) x GEN_W, on Icarus+Verilator.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RAW=evidence/raw; FL=sim/filelists; mkdir -p "$RAW" sim/icarus sim/verilator
# DEPTH GEN_W  (EPOCH_W OP_W META_W TS_W fixed)
CONFIGS=("1 2" "2 4" "3 2" "4 4" "7 2" "8 4" "16 4")
DEFS="-DEPOCHW=16 -DOPW=2 -DMETAW=16 -DTSW=8"
fail=0
echo "## regenerate tracker vectors"; ( cd tb/models && python3 gen_tracker_vectors.py ) | sed 's/^/   /'
echo "## lint"; verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM \
  rtl/core/outstanding_tracker.sv --top-module outstanding_tracker > "$RAW/lint_tracker.log" 2>&1
lrc=$?; if [ $lrc -ne 0 ] || grep -qE "%Warning|%Error" "$RAW/lint_tracker.log"; then echo "   LINT FAIL"; grep -E "%Warning|%Error" "$RAW/lint_tracker.log"|sed 's/^/   /'; fail=1; else echo "   lint clean"; fi
for c in "${CONFIGS[@]}"; do
  read -r D G <<<"$c"; vec="tb/vectors/tracker_${D}d_${G}g.vec"; tag="ot_${D}d_${G}g"
  iverilog -g2012 -DDEPTH=$D -DGENW=$G $DEFS -c "$FL/tb_outstanding_tracker.f" -o "sim/icarus/${tag}.vvp" >"$RAW/icarus_${tag}_c.log" 2>&1 \
    && vvp "sim/icarus/${tag}.vvp" +VEC=$vec > "$RAW/icarus_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/icarus_${tag}_run.log" && ip=PASS || { ip=FAIL; fail=1; }
  rm -rf "sim/verilator/obj_${tag}"
  verilator --binary --timing -Wno-fatal -DDEPTH=$D -DGENW=$G $DEFS -f "$FL/tb_outstanding_tracker.f" \
    --Mdir "sim/verilator/obj_${tag}" --top-module tb_outstanding_tracker >"$RAW/verilator_${tag}_b.log" 2>&1
  [ -x "sim/verilator/obj_${tag}/Vtb_outstanding_tracker" ] && "sim/verilator/obj_${tag}/Vtb_outstanding_tracker" +VEC=$vec > "$RAW/verilator_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/verilator_${tag}_run.log" && vp=PASS || { vp=FAIL; fail=1; }
  ck=$(grep -oE "checks=[0-9]+" "$RAW/icarus_${tag}_run.log"|head -1)
  printf "   %-14s icarus=%-4s(%s) verilator=%-4s\n" "$tag" "$ip" "$ck" "$vp"
done
echo "=================================================="
[ $fail -eq 0 ] && echo "TRACKER SWEEP: PASS" || echo "TRACKER SWEEP: FAIL"
exit $fail
