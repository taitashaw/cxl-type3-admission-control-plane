#!/usr/bin/env bash
# run_cdc_sweep.sh — event-driven two-clock differential for async_fifo (M7).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RAW=evidence/raw; FL=sim/filelists; mkdir -p "$RAW" sim/icarus sim/verilator
CONFIGS=("2 2" "4 2" "8 3" "3 4")
fail=0
echo "## regenerate async_fifo vectors"; ( cd tb/models && python3 async_fifo_model.py ) | sed 's/^/   /'
echo "## lint"; verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
  rtl/core/sync_bits.sv rtl/core/async_fifo.sv --top-module async_fifo > "$RAW/lint_cdc.log" 2>&1
lrc=$?; if [ $lrc -ne 0 ] || grep -qE "%Warning|%Error" "$RAW/lint_cdc.log"; then echo "   LINT FAIL"; grep -E "%Warning|%Error" "$RAW/lint_cdc.log"|sed 's/^/   /'; fail=1; else echo "   lint clean"; fi
for c in "${CONFIGS[@]}"; do
  read -r W A <<<"$c"
  vec="tb/vectors/afifo_${W}w_${A}a.vec"; tag="afifo_${W}w_${A}a"
  DEFS="-DWIDTHP=$W -DADDRWP=$A"
  iverilog -g2012 $DEFS -c "$FL/tb_async_fifo.f" -o "sim/icarus/${tag}.vvp" >"$RAW/icarus_${tag}_c.log" 2>&1 \
    && vvp "sim/icarus/${tag}.vvp" +VEC=$vec > "$RAW/icarus_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/icarus_${tag}_run.log" && ip=PASS || { ip=FAIL; fail=1; }
  rm -rf "sim/verilator/obj_${tag}"
  verilator --binary --timing -Wno-fatal $DEFS -f "$FL/tb_async_fifo.f" \
    --Mdir "sim/verilator/obj_${tag}" --top-module tb_async_fifo >"$RAW/verilator_${tag}_b.log" 2>&1
  [ -x "sim/verilator/obj_${tag}/Vtb_async_fifo" ] && "sim/verilator/obj_${tag}/Vtb_async_fifo" +VEC=$vec > "$RAW/verilator_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/verilator_${tag}_run.log" && vp=PASS || { vp=FAIL; fail=1; }
  ck=$(grep -oE "checks=[0-9]+" "$RAW/icarus_${tag}_run.log"|head -1)
  printf "   %-12s icarus=%-4s(%s) verilator=%-4s\n" "$tag" "$ip" "$ck" "$vp"
done
echo "=================================================="
[ $fail -eq 0 ] && echo "CDC SWEEP: PASS" || echo "CDC SWEEP: FAIL"
exit $fail
