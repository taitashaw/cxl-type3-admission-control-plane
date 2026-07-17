#!/usr/bin/env bash
# run_hdm_regression.sh — full FREE-lane M1 regression:
#   * (re)generate differential vectors from the independent Python model
#   * lint project-owned RTL (Verilator -Wall)
#   * decoder+translator differential sweep  (1/2/4/8 windows, both engines)
#   * config commit-protocol sweep           (1/2/4/8 windows, both engines)
# Fails unless EVERY (tb, config, engine) reports TB_RESULT: PASS and lint is clean.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RAW=evidence/raw; FL=sim/filelists; mkdir -p "$RAW" sim/icarus sim/verilator
CONFIGS=("1 32 24" "2 40 32" "4 40 32" "8 44 36")
fail=0

echo "## regenerate vectors"
( cd tb/models && python3 gen_vectors.py ) | sed 's/^/   /'

echo "## lint (Verilator -Wall, project-owned RTL via $FL/rtl.f)"
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM \
  -f "$FL/rtl.f" --top-module hdm_decode_top > "$RAW/lint_core.log" 2>&1
lrc=$?
# Robust across Verilator versions: fail only on real warnings/errors or a
# non-zero exit (newer Verilator prints a benign report line even on success).
if [ $lrc -ne 0 ] || grep -qE "%Warning|%Error" "$RAW/lint_core.log"; then
  echo "   LINT WARNINGS/ERRORS:"; grep -E "%Warning|%Error" "$RAW/lint_core.log" | sed 's/^/   /'; fail=1
else echo "   lint clean"; fi

run_one() { # tb_name vecprefix N H D
  local tb=$1 pfx=$2 N=$3 H=$4 D=$5
  local vec="tb/vectors/${pfx}_${N}w_${H}x${D}.vec"
  local tag="${tb}_${N}w_${H}x${D}"
  local flist="$FL/${tb}.f"
  # Icarus (-c reads the ordered source manifest; no textual includes)
  iverilog -g2012 -DNWIN=$N -DHPAW=$H -DDPAW=$D -c "$flist" \
    -o "sim/icarus/${tag}.vvp" > "$RAW/icarus_${tag}_c.log" 2>&1 \
    && vvp "sim/icarus/${tag}.vvp" +VEC=$vec > "$RAW/icarus_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/icarus_${tag}_run.log" && ip=PASS || { ip=FAIL; fail=1; }
  # Verilator (-f reads the same manifest)
  rm -rf "sim/verilator/obj_${tag}"
  verilator --binary --timing -Wno-fatal -DNWIN=$N -DHPAW=$H -DDPAW=$D \
    -f "$flist" --Mdir "sim/verilator/obj_${tag}" --top-module $tb > "$RAW/verilator_${tag}_b.log" 2>&1
  [ -x "sim/verilator/obj_${tag}/V${tb}" ] && "sim/verilator/obj_${tag}/V${tb}" +VEC=$vec > "$RAW/verilator_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/verilator_${tag}_run.log" && vp=PASS || { vp=FAIL; fail=1; }
  local ic=$(grep -oE "checks=[0-9]+" "$RAW/icarus_${tag}_run.log" | head -1)
  printf "   %-26s icarus=%-4s(%s) verilator=%-4s\n" "$tag" "$ip" "$ic" "$vp"
}

echo "## decoder+translator differential sweep"
for c in "${CONFIGS[@]}"; do read -r N H D <<<"$c"; run_one tb_hdm_decoder dec $N $H $D; done
echo "## config commit-protocol sweep"
for c in "${CONFIGS[@]}"; do read -r N H D <<<"$c"; run_one tb_hdm_config cfg $N $H $D; done

echo "=================================================="
[ $fail -eq 0 ] && echo "HDM REGRESSION: PASS" || echo "HDM REGRESSION: FAIL"
exit $fail
