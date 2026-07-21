#!/usr/bin/env bash
# run_system_sweep.sh — self-checking end-to-end scoreboard for system_top (M8):
# admitted request -> req CDC -> mem_subsys -> rsp CDC -> response, over two
# INDEPENDENT clocks. Verifies read-after-write across the clock-domain crossing.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RAW=evidence/raw; FL=sim/filelists; mkdir -p "$RAW" sim/icarus sim/verilator
# TAG ADDR DATA DEPTH CQ FIFO_AW
CONFIGS=("6 3 8 4 4 2" "5 2 8 2 2 2" "6 4 8 4 4 3" "7 3 4 3 3 2")
NTXN=4000
fail=0
echo "## lint"; verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-PINMISSING \
  rtl/core/sync_bits.sv rtl/core/async_fifo.sv rtl/core/rw_scheduler.sv rtl/core/mem_backend.sv \
  rtl/core/mem_subsys_top.sv rtl/core/system_top.sv --top-module system_top > "$RAW/lint_system.log" 2>&1
lrc=$?; if [ $lrc -ne 0 ] || grep -qE "%Warning|%Error" "$RAW/lint_system.log"; then echo "   LINT FAIL"; grep -E "%Warning|%Error" "$RAW/lint_system.log"|sed 's/^/   /'; fail=1; else echo "   lint clean"; fi
for c in "${CONFIGS[@]}"; do
  read -r TW AW DW D CQ FAW <<<"$c"
  tag="sys_${TW}t_${AW}a_${D}n_${CQ}q_${FAW}f"
  DEFS="-DTAGW=$TW -DADDRW=$AW -DDATAW=$DW -DDEPTHP=$D -DCQDP=$CQ -DFAWP=$FAW -DNTXN=$NTXN"
  iverilog -g2012 $DEFS -c "$FL/tb_system_top.f" -o "sim/icarus/${tag}.vvp" >"$RAW/icarus_${tag}_c.log" 2>&1 \
    && timeout 300 vvp "sim/icarus/${tag}.vvp" > "$RAW/icarus_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/icarus_${tag}_run.log" && ip=PASS || { ip=FAIL; fail=1; }
  rm -rf "sim/verilator/obj_${tag}"
  verilator --binary --timing -Wno-fatal $DEFS -f "$FL/tb_system_top.f" \
    --Mdir "sim/verilator/obj_${tag}" --top-module tb_system_top -o "sys_${tag}" >"$RAW/verilator_${tag}_b.log" 2>&1
  bin=$(ls "sim/verilator/obj_${tag}/sys_${tag}" "sim/verilator/obj_${tag}/Vtb_system_top" 2>/dev/null | head -1)
  [ -x "$bin" ] && timeout 300 "$bin" > "$RAW/verilator_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/verilator_${tag}_run.log" && vp=PASS || { vp=FAIL; fail=1; }
  ck=$(grep -oE "checks=[0-9]+" "$RAW/icarus_${tag}_run.log"|head -1)
  printf "   %-22s icarus=%-4s(%s) verilator=%-4s\n" "$tag" "$ip" "$ck" "$vp"
done
echo "=================================================="
[ $fail -eq 0 ] && echo "SYSTEM SWEEP: PASS" || echo "SYSTEM SWEEP: FAIL"
exit $fail
