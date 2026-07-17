#!/usr/bin/env bash
# run_formal.sh — SymbiYosys formal proofs for the decoder/translator and the
# config FSM, using a project-local OSS CAD Suite (no root). Each .sby runs a
# bounded model check (bmc) and an unbounded safety proof (prove/induction).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RAW=evidence/raw; mkdir -p "$RAW"
ENV=tools/oss-cad-suite/environment
if [ ! -f "$ENV" ]; then
  echo "FORMAL: BLOCKED — OSS CAD Suite not extracted at tools/oss-cad-suite."
  echo "  Run: scripts/bootstrap_formal.sh   (downloads + verifies + extracts, no sudo)"
  exit 3
fi
source "$ENV"
echo "using $(yosys --version 2>/dev/null | head -1); $(sby --help 2>&1 | head -1 | sed 's/usage:.*//')sby present"

fail=0
for job in decode config tracker credit; do
  rm -rf "formal/${job}_bmc" "formal/${job}_prove" "formal/${job}_cover"
  sby -f "formal/${job}.sby" > "$RAW/formal_${job}.log" 2>&1
  bmc=$(grep -c "\[formal/${job}_bmc\] DONE (PASS" "$RAW/formal_${job}.log")
  prv=$(grep -c "\[formal/${job}_prove\] DONE (PASS" "$RAW/formal_${job}.log")
  cov=$(grep -c "\[formal/${job}_cover\] DONE (PASS" "$RAW/formal_${job}.log")
  if [ "$bmc" -ge 1 ] && [ "$prv" -ge 1 ] && [ "$cov" -ge 1 ]; then
    echo "   ${job}: bmc=PASS prove(induction)=PASS cover(non-vacuity)=PASS"
  else
    echo "   ${job}: FAIL (bmc=$bmc prove=$prv cover=$cov; see $RAW/formal_${job}.log)"; fail=1
  fi
done
echo "-- tracker formal parameter instances (5 tuples, each prove+cover = 10 tasks) --"
for d in formal/tracker_matrix_*; do rm -rf "$d"; done
sby -f formal/tracker_matrix.sby > "$RAW/formal_tracker_matrix.log" 2>&1
mtot=$(grep -c "DONE (" "$RAW/formal_tracker_matrix.log"); mpass=$(grep -c "DONE (PASS" "$RAW/formal_tracker_matrix.log")
echo "   tracker matrix: $mpass/$mtot tasks PASS"
[ "$mpass" = "$mtot" ] && [ "$mtot" -gt 0 ] || fail=1
echo "-- credit formal parameter instances (5 tuples, each prove+cover = 10 tasks) --"
for d in formal/credit_matrix_*; do rm -rf "$d"; done
sby -f formal/credit_matrix.sby > "$RAW/formal_credit_matrix.log" 2>&1
cmtot=$(grep -c "DONE (" "$RAW/formal_credit_matrix.log"); cmpass=$(grep -c "DONE (PASS" "$RAW/formal_credit_matrix.log")
echo "   credit matrix: $cmpass/$cmtot tasks PASS"
[ "$cmpass" = "$cmtot" ] && [ "$cmtot" -gt 0 ] || fail=1
echo "-- non-vacuity: proofs must fail when protections are broken --"
bash scripts/run_formal_mutation.sh > "$RAW/formal_mutation.log" 2>&1
grep -E "killed=|SURVIVED" "$RAW/formal_mutation.log" | sed 's/^/   /'
grep -q "FORMAL MUTATION: PASS" "$RAW/formal_mutation.log" || { echo "   formal-mutation FAIL"; fail=1; }
echo "=================================================="
[ $fail -eq 0 ] && echo "FORMAL: PASS (bounded + unbounded proofs + covers reached)" || echo "FORMAL: FAIL"
exit $fail
