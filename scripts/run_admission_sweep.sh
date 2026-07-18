#!/usr/bin/env bash
# run_admission_sweep.sh — differential regression for admission_top (M4 Phase 2b)
# across (N_POOLS,AMT_W,COUNT_W,RESET_MAX,DEPTH,GEN_W) on Icarus + Verilator.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RAW=evidence/raw; FL=sim/filelists; mkdir -p "$RAW" sim/icarus sim/verilator
# NP AW CW RM D G  (EPOCH_W OP_W META_W TS_W fixed at 8/2/8/8)
CONFIGS=("2 3 6 8 4 4" "1 2 4 3 3 2" "3 2 5 6 5 3" "2 4 7 12 8 4")
DEFS_FIXED="-DEPOCHW=8 -DOPW=2 -DMETAW=8 -DTSW=8"
VDEFS_FIXED="-DEPOCHW=8 -DOPW=2 -DMETAW=8 -DTSW=8"
fail=0
echo "## regenerate admission vectors"; ( cd tb/models && python3 gen_admission_vectors.py ) | sed 's/^/   /'
echo "## lint"; verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
  -Irtl/core rtl/core/admission_top.sv --top-module admission_top > "$RAW/lint_admission.log" 2>&1
lrc=$?; if [ $lrc -ne 0 ] || grep -qE "%Warning|%Error" "$RAW/lint_admission.log"; then echo "   LINT FAIL"; grep -E "%Warning|%Error" "$RAW/lint_admission.log"|sed 's/^/   /'; fail=1; else echo "   lint clean"; fi
for c in "${CONFIGS[@]}"; do
  read -r NP AW CW RM D G <<<"$c"
  vec="tb/vectors/adm_${NP}p_${AW}a_${CW}c_${RM}m_${D}d_${G}g.vec"; tag="adm_${NP}p_${AW}a_${D}d"
  DEFS="-DNPOOLS=$NP -DAMTW=$AW -DCOUNTW=$CW -DRESETMAX=$RM -DDEPTH=$D -DGENW=$G $DEFS_FIXED"
  iverilog -g2012 $DEFS -c "$FL/tb_admission_top.f" -o "sim/icarus/${tag}.vvp" >"$RAW/icarus_${tag}_c.log" 2>&1 \
    && vvp "sim/icarus/${tag}.vvp" +VEC=$vec > "$RAW/icarus_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/icarus_${tag}_run.log" && ip=PASS || { ip=FAIL; fail=1; }
  rm -rf "sim/verilator/obj_${tag}"
  verilator --binary --timing -Wno-fatal -DNPOOLS=$NP -DAMTW=$AW -DCOUNTW=$CW -DRESETMAX=$RM -DDEPTH=$D -DGENW=$G $VDEFS_FIXED \
    -f "$FL/tb_admission_top.f" --Mdir "sim/verilator/obj_${tag}" --top-module tb_admission_top >"$RAW/verilator_${tag}_b.log" 2>&1
  [ -x "sim/verilator/obj_${tag}/Vtb_admission_top" ] && "sim/verilator/obj_${tag}/Vtb_admission_top" +VEC=$vec > "$RAW/verilator_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/verilator_${tag}_run.log" && vp=PASS || { vp=FAIL; fail=1; }
  ck=$(grep -oE "checks=[0-9]+" "$RAW/icarus_${tag}_run.log"|head -1)
  printf "   %-18s icarus=%-4s(%s) verilator=%-4s\n" "$tag" "$ip" "$ck" "$vp"
done
echo "=================================================="
[ $fail -eq 0 ] && echo "ADMISSION SWEEP: PASS" || echo "ADMISSION SWEEP: FAIL"
exit $fail
