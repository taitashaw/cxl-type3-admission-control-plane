#!/usr/bin/env bash
# run_mem_backend_sweep.sh — differential regression for mem_backend (M6)
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RAW=evidence/raw; FL=sim/filelists; mkdir -p "$RAW" sim/icarus sim/verilator
CONFIGS=("6 4 8 4" "5 2 4 2" "6 3 8 3" "7 2 8 8")
fail=0
echo "## regenerate mem_backend vectors"; ( cd tb/models && python3 gen_mem_backend_vectors.py ) | sed 's/^/   /'
echo "## lint"; verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
  rtl/core/mem_backend.sv --top-module mem_backend > "$RAW/lint_mem_backend.log" 2>&1
lrc=$?; if [ $lrc -ne 0 ] || grep -qE "%Warning|%Error" "$RAW/lint_mem_backend.log"; then echo "   LINT FAIL"; grep -E "%Warning|%Error" "$RAW/lint_mem_backend.log"|sed 's/^/   /'; fail=1; else echo "   lint clean"; fi
for c in "${CONFIGS[@]}"; do
  read -r TW AW DW CQ <<<"$c"
  vec="tb/vectors/mem_${TW}t_${AW}a_${DW}d_${CQ}q.vec"; tag="mem_${TW}t_${AW}a_${CQ}q"
  DEFS="-DTAGW=$TW -DADDRW=$AW -DDATAW=$DW -DCQD=$CQ"
  iverilog -g2012 $DEFS -c "$FL/tb_mem_backend.f" -o "sim/icarus/${tag}.vvp" >"$RAW/icarus_${tag}_c.log" 2>&1 \
    && vvp "sim/icarus/${tag}.vvp" +VEC=$vec > "$RAW/icarus_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/icarus_${tag}_run.log" && ip=PASS || { ip=FAIL; fail=1; }
  rm -rf "sim/verilator/obj_${tag}"
  verilator --binary --timing -Wno-fatal $DEFS -f "$FL/tb_mem_backend.f" \
    --Mdir "sim/verilator/obj_${tag}" --top-module tb_mem_backend >"$RAW/verilator_${tag}_b.log" 2>&1
  [ -x "sim/verilator/obj_${tag}/Vtb_mem_backend" ] && "sim/verilator/obj_${tag}/Vtb_mem_backend" +VEC=$vec > "$RAW/verilator_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/verilator_${tag}_run.log" && vp=PASS || { vp=FAIL; fail=1; }
  ck=$(grep -oE "checks=[0-9]+" "$RAW/icarus_${tag}_run.log"|head -1)
  printf "   %-14s icarus=%-4s(%s) verilator=%-4s\n" "$tag" "$ip" "$ck" "$vp"
done
echo "=================================================="
[ $fail -eq 0 ] && echo "MEM_BACKEND SWEEP: PASS" || echo "MEM_BACKEND SWEEP: FAIL"
exit $fail
