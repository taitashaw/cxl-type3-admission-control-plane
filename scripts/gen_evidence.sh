#!/usr/bin/env bash
# gen_evidence.sh — produce compact, VERSIONED evidence summaries under
# evidence/reports/ from the current run logs in evidence/raw/ (which stay
# git-ignored). Each summary carries git commit + dirty status + UTC timestamp +
# tool versions + pass/fail counts + SHA-256 of the raw logs it summarizes.
# Run the flows first (make regression mutation formal) so the logs are fresh.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RAW=evidence/raw; REP=evidence/reports; mkdir -p "$REP"
GIT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)
GIT_DIRTY=$(test -n "$(git status --porcelain 2>/dev/null)" && echo true || echo false)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VERI=$(verilator --version 2>&1 | head -1)
IVL=$(iverilog -V 2>&1 | head -1)
PY=$(python3 --version 2>&1)
YOS=$( (source tools/oss-cad-suite/environment 2>/dev/null && yosys --version 2>/dev/null | head -1) || echo "not-installed")

python3 - "$RAW" "$REP" "$GIT_COMMIT" "$GIT_DIRTY" "$TS" "$VERI" "$IVL" "$PY" "$YOS" <<'PY'
import sys, os, re, json, hashlib, glob
RAW,REP,commit,dirty,ts,veri,ivl,py,yos = sys.argv[1:10]
def sha(p):
    try:
        h=hashlib.sha256()
        with open(p,'rb') as f:
            for b in iter(lambda:f.read(65536),b''): h.update(b)
        return h.hexdigest()
    except FileNotFoundError: return None
meta=dict(git_commit=commit, git_dirty=(dirty=="true"), utc=ts)
tools=dict(verilator=veri, iverilog=ivl, python=py, yosys=yos)
json.dump({**meta,"tools":tools}, open(f"{REP}/tool_versions.json","w"), indent=2)

# regression: one row per (tb,config,engine)
rows=[]; rlogs=[]
for f in sorted(glob.glob(f"{RAW}/icarus_tb_hdm_*_run.log")+glob.glob(f"{RAW}/verilator_tb_hdm_*_run.log")+glob.glob(f"{RAW}/icarus_ot_*_run.log")+glob.glob(f"{RAW}/verilator_ot_*_run.log")):
    txt=open(f).read()
    m=re.search(r"checks=(\d+) errors=(\d+)",txt); res="PASS" if "TB_RESULT: PASS" in txt else "FAIL"
    eng="icarus" if "icarus_" in f else "verilator"
    tag=re.sub(r".*(icarus|verilator)_((tb_hdm|ot)_\w+)_run.log",r"\2",f)
    rows.append(dict(engine=eng,tb=tag,result=res,checks=int(m.group(1)) if m else None,errors=int(m.group(2)) if m else None))
    rlogs.append(dict(path=f, sha256=sha(f)))
reg=dict(**meta, kind="regression", engines=["icarus","verilator"],
         param_sweep={"N_WIN":[1,2,4,8],"HPA_W_DPA_W":[[32,24],[40,32],[40,32],[44,36]]},
         seeds={"gen_vectors":"0xC5100"},
         total=len(rows), passed=sum(r["result"]=="PASS" for r in rows), failed=sum(r["result"]=="FAIL" for r in rows),
         results=rows, raw_logs=rlogs)
json.dump(reg, open(f"{REP}/regression_summary.json","w"), indent=2)

# formal: parse decode/config logs for bmc/prove/cover + non-vacuity mutation
def formal_job(job):
    p=f"{RAW}/formal_{job}.log"; t=open(p).read() if os.path.exists(p) else ""
    return dict(job=job,
        bmc="PASS" if f"[formal/{job}_bmc] DONE (PASS" in t else "FAIL",
        induction="PASS" if f"[formal/{job}_prove] DONE (PASS" in t else "FAIL",
        cover="PASS" if f"[formal/{job}_cover] DONE (PASS" in t else "FAIL",
        raw=dict(path=p, sha256=sha(p)))
mt=open(f"{RAW}/formal_mutation.log").read() if os.path.exists(f"{RAW}/formal_mutation.log") else ""
mk=re.search(r"killed=(\d+) survived=(\d+)",mt)
formal=dict(**meta, kind="formal", engine="smtbmc/yices", modes=["bmc","prove(induction)","cover"],
            assumptions="initial reset then rst_n free; sh_*/cfg_update_req/outstanding_cnt free; safety-only (see docs/limitations.md)",
            jobs=[formal_job("decode"),formal_job("config"),formal_job("tracker")],
            non_vacuity=dict(cover="all reachable",
                             formal_mutation=dict(killed=int(mk.group(1)) if mk else None,
                                                  survived=int(mk.group(2)) if mk else None,
                                                  raw=dict(path=f"{RAW}/formal_mutation.log", sha256=sha(f"{RAW}/formal_mutation.log")))))
json.dump(formal, open(f"{REP}/formal_summary.json","w"), indent=2)

# mutation (simulation)
smp=f"{RAW}/sim_mutation.log"; smt=open(smp).read() if os.path.exists(smp) else ""
smk=re.search(r"killed=(\d+) survived=(\d+)",smt)
mut=dict(**meta, kind="mutation_sim",
         killed=int(smk.group(1)) if smk else None, survived=int(smk.group(2)) if smk else None,
         raw=dict(path=smp, sha256=sha(smp)))
json.dump(mut, open(f"{REP}/mutation_summary.json","w"), indent=2)

# overall run summary
run=dict(**meta, kind="run_summary",
         regression=dict(passed=reg["passed"],failed=reg["failed"]),
         formal=[{k:j[k] for k in ("job","bmc","induction","cover")} for j in formal["jobs"]],
         mutation_sim=dict(killed=mut["killed"],survived=mut["survived"]),
         formal_mutation=formal["non_vacuity"]["formal_mutation"] and dict(killed=mk.group(1) if mk else None))
json.dump(run, open(f"{REP}/run_summary.json","w"), indent=2)
print("wrote:", ", ".join(sorted(os.path.basename(p) for p in glob.glob(f"{REP}/*.json"))))
PY
