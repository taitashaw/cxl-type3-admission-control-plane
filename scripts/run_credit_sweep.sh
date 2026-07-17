#!/usr/bin/env bash
# run_credit_sweep.sh — differential regression for credit_manager across
# N_POOLS {1,2,3} x maxima {1,2,3,7,8} x count/amount widths, Icarus+Verilator.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RAW=evidence/raw; FL=sim/filelists; mkdir -p "$RAW" sim/icarus sim/verilator
# N_POOLS COUNT_W AMT_W RESET_MAX  (must match gen_credit_vectors.py CONFIGS)
CONFIGS=("1 4 2 1" "2 4 2 3" "3 5 3 7" "2 6 3 8" "1 3 2 2")
fail=0
echo "## regenerate credit vectors"; ( cd tb/models && python3 gen_credit_vectors.py ) | sed 's/^/   /'
echo "## lint"
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM rtl/core/credit_manager.sv \
  --top-module credit_manager > "$RAW/lint_credit.log" 2>&1
lrc=$?
if [ $lrc -ne 0 ] || grep -qE "%Warning|%Error" "$RAW/lint_credit.log"; then
  echo "   LINT FAIL"; grep -E "%Warning|%Error" "$RAW/lint_credit.log" | sed 's/^/   /'; fail=1
else echo "   lint clean"; fi
for c in "${CONFIGS[@]}"; do
  read -r N CW AW RM <<<"$c"
  vec="tb/vectors/credit_${N}p_${CW}c_${AW}a.vec"; tag="cm_${N}p_${CW}c_${AW}a"
  D="-DNPOOLS=$N -DCOUNTW=$CW -DAMTW=$AW -DRESETMAX=$RM"
  iverilog -g2012 $D -c "$FL/tb_credit_manager.f" -o "sim/icarus/${tag}.vvp" >"$RAW/icarus_${tag}_c.log" 2>&1 \
    && vvp "sim/icarus/${tag}.vvp" +VEC=$vec > "$RAW/icarus_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/icarus_${tag}_run.log" && ip=PASS || { ip=FAIL; fail=1; }
  rm -rf "sim/verilator/obj_${tag}"
  verilator --binary --timing -Wno-fatal $D -f "$FL/tb_credit_manager.f" \
    --Mdir "sim/verilator/obj_${tag}" --top-module tb_credit_manager >"$RAW/verilator_${tag}_b.log" 2>&1
  [ -x "sim/verilator/obj_${tag}/Vtb_credit_manager" ] && "sim/verilator/obj_${tag}/Vtb_credit_manager" +VEC=$vec > "$RAW/verilator_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/verilator_${tag}_run.log" && vp=PASS || { vp=FAIL; fail=1; }
  ck=$(grep -oE "checks=[0-9]+" "$RAW/icarus_${tag}_run.log"|head -1)
  printf "   %-16s icarus=%-4s(%s) verilator=%-4s\n" "$tag" "$ip" "$ck" "$vp"
done
echo "=================================================="
[ $fail -eq 0 ] && echo "CREDIT SWEEP: PASS" || echo "CREDIT SWEEP: FAIL"
exit $fail
