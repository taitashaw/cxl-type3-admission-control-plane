#!/usr/bin/env bash
# run_memsubsys_sweep.sh — differential regression for mem_subsys_top (M6)
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RAW=evidence/raw; FL=sim/filelists; mkdir -p "$RAW" sim/icarus sim/verilator
CONFIGS=("6 2 8 4 4" "5 1 4 2 2" "6 2 8 3 3" "7 3 8 4 4")
fail=0
echo "## regenerate mem_subsys vectors"; ( cd tb/models && python3 gen_memsubsys_vectors.py ) | sed 's/^/   /'
echo "## lint"; verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
  rtl/core/rw_scheduler.sv rtl/core/mem_backend.sv rtl/core/mem_subsys_top.sv --top-module mem_subsys_top > "$RAW/lint_memsubsys.log" 2>&1
lrc=$?; if [ $lrc -ne 0 ] || grep -qE "%Warning|%Error" "$RAW/lint_memsubsys.log"; then echo "   LINT FAIL"; grep -E "%Warning|%Error" "$RAW/lint_memsubsys.log"|sed 's/^/   /'; fail=1; else echo "   lint clean"; fi
for c in "${CONFIGS[@]}"; do
  read -r TW AW DW D CQ <<<"$c"
  vec="tb/vectors/msy_${TW}t_${AW}a_${DW}d_${D}n_${CQ}q.vec"; tag="msy_${TW}t_${AW}a_${D}n"
  DEFS="-DTAGW=$TW -DADDRW=$AW -DDATAW=$DW -DDEPTH=$D -DCQD=$CQ"
  iverilog -g2012 $DEFS -c "$FL/tb_mem_subsys_top.f" -o "sim/icarus/${tag}.vvp" >"$RAW/icarus_${tag}_c.log" 2>&1 \
    && vvp "sim/icarus/${tag}.vvp" +VEC=$vec > "$RAW/icarus_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/icarus_${tag}_run.log" && ip=PASS || { ip=FAIL; fail=1; }
  rm -rf "sim/verilator/obj_${tag}"
  verilator --binary --timing -Wno-fatal $DEFS -f "$FL/tb_mem_subsys_top.f" \
    --Mdir "sim/verilator/obj_${tag}" --top-module tb_mem_subsys_top >"$RAW/verilator_${tag}_b.log" 2>&1
  [ -x "sim/verilator/obj_${tag}/Vtb_mem_subsys_top" ] && "sim/verilator/obj_${tag}/Vtb_mem_subsys_top" +VEC=$vec > "$RAW/verilator_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/verilator_${tag}_run.log" && vp=PASS || { vp=FAIL; fail=1; }
  ck=$(grep -oE "checks=[0-9]+" "$RAW/icarus_${tag}_run.log"|head -1)
  printf "   %-14s icarus=%-4s(%s) verilator=%-4s\n" "$tag" "$ip" "$ck" "$vp"
done
echo "=================================================="
[ $fail -eq 0 ] && echo "MEM_SUBSYS SWEEP: PASS" || echo "MEM_SUBSYS SWEEP: FAIL"
exit $fail
