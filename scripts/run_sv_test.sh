#!/usr/bin/env bash
# run_sv_test.sh <testname> <top_module> <source files...>
# Compiles and runs a self-checking SystemVerilog testbench under BOTH Icarus
# and Verilator, greps the "TB_RESULT: PASS|FAIL" banner from each, and fails
# (non-zero exit) unless BOTH engines report PASS. Raw logs go to evidence/raw/.
#
# Rationale for dual-engine: the two simulators use independent front-ends and
# schedulers; requiring agreement catches engine-specific evaluation bugs (this
# project already found one — see docs/limitations.md).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NAME="$1"; TOP="$2"; shift 2
SRCS="$*"
RAW="evidence/raw"; mkdir -p "$RAW" sim/icarus sim/verilator
INC="-Irtl/interfaces"

pass_icarus=0; pass_veri=0

echo "### [$NAME] ICARUS ###"
if iverilog -g2012 -grelative-include -Irtl/interfaces \
     -o "sim/icarus/${NAME}.vvp" $SRCS > "$RAW/icarus_${NAME}_compile.log" 2>&1; then
  vvp "sim/icarus/${NAME}.vvp" > "$RAW/icarus_${NAME}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/icarus_${NAME}_run.log" && pass_icarus=1
fi
grep -E "checks=|TB_RESULT" "$RAW/icarus_${NAME}_run.log" 2>/dev/null || echo "  (icarus produced no result — see compile log)"

echo "### [$NAME] VERILATOR ###"
rm -rf "sim/verilator/obj_${NAME}"
# single-threaded build: -j 0 can hit a 5.020 threadpool-cleanup abort on exit
if verilator --binary --timing -Wno-fatal $INC \
     --Mdir "sim/verilator/obj_${NAME}" --top-module "$TOP" $SRCS \
     > "$RAW/verilator_${NAME}_build.log" 2>&1; then
  "./sim/verilator/obj_${NAME}/V${TOP}" > "$RAW/verilator_${NAME}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/verilator_${NAME}_run.log" && pass_veri=1
fi
grep -E "checks=|TB_RESULT" "$RAW/verilator_${NAME}_run.log" 2>/dev/null || echo "  (verilator produced no result — see build log)"

echo "### [$NAME] SUMMARY: icarus=$([ $pass_icarus = 1 ] && echo PASS || echo FAIL)  verilator=$([ $pass_veri = 1 ] && echo PASS || echo FAIL) ###"
if [ $pass_icarus = 1 ] && [ $pass_veri = 1 ]; then
  echo "OVERALL: PASS ($NAME)"; exit 0
else
  echo "OVERALL: FAIL ($NAME)"; exit 1
fi
