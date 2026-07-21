#!/usr/bin/env bash
# run_xsim_crosscheck.sh — third-engine (AMD XSim) cross-check on a REDUCED
# golden set, for the 4-window/40x32 config. Compares architectural PASS/FAIL
# against the Icarus/Verilator result. XSim is licence-metered and slower, so a
# reduced vector subset is used (reviewer's "reduced golden-vector suite").
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RAW=evidence/raw; XD=sim/xsim; mkdir -p "$RAW" "$XD"
command -v xvlog >/dev/null || { echo "XSIM: BLOCKED (xvlog not found)"; exit 3; }

# Build reduced vec files (header count adjusted to first N vectors)
reduce() { # src dst N
  python3 - "$1" "$2" "$3" <<'PY'
import sys
src,dst,n=sys.argv[1],sys.argv[2],int(sys.argv[3])
lines=open(src).read().splitlines()
hdr=lines[0].split()
body=lines[1:1+n]
hdr[-1]=str(len(body))
open(dst,'w').write(" ".join(hdr)+"\n"+"\n".join(body)+"\n")
PY
}
reduce tb/vectors/dec_4w_40x32.vec "$XD/dec_red.vec" 400
reduce tb/vectors/cfg_4w_40x32.vec "$XD/cfg_red.vec" 400
reduce tb/vectors/tracker_8d_4g.vec "$XD/ot_red.vec" 400
reduce tb/vectors/credit_2p_4c_2a_32d.vec "$XD/cm_red.vec" 400
reduce tb/vectors/adm_2p_3a_6c_8m_4d_4g.vec "$XD/adm_red.vec" 400
reduce tb/vectors/cp_2p_3a_6c_8m_4d_4g.vec "$XD/cp_red.vec" 400
reduce tb/vectors/sch_6t_2a_8d_4n.vec "$XD/sch_red.vec" 400
reduce tb/vectors/mem_6t_4a_8d_4q.vec "$XD/mem_red.vec" 400
reduce tb/vectors/msy_6t_2a_8d_4n_4q.vec "$XD/msy_red.vec" 400
reduce tb/vectors/afifo_8w_3a.vec "$XD/afifo_red.vec" 400

fail=0
run_xsim() { # tb srcs vecbasename tag defines
  local tb=$1 srcs=$2 vec=$3 tag=$4 defs=${5:-"-d NWIN=4 -d HPAW=40 -d DPAW=32"}
  ( cd "$XD" && rm -rf xsim.dir ${tag}_snap* 2>/dev/null
    xvlog -sv $defs -i ../../rtl/interfaces $srcs                             > "xvlog_${tag}.log" 2>&1
    xelab $tb -s ${tag}_snap -timescale 1ns/1ps                               > "xelab_${tag}.log" 2>&1
    xsim ${tag}_snap -R -testplusarg "VEC=$vec"                               > "xsim_${tag}.log" 2>&1 )
  cp "$XD/xsim_${tag}.log" "$RAW/xsim_${tag}_run.log" 2>/dev/null
  if grep -q "TB_RESULT: PASS" "$XD/xsim_${tag}.log"; then
    echo "   $tag : XSim PASS ($(grep -oE 'checks=[0-9]+' "$XD/xsim_${tag}.log" | head -1))"
  else
    echo "   $tag : XSim FAIL"; grep -E "ERROR|TB_RESULT|Error" "$XD/xsim_${tag}.log" | head -5; fail=1
  fi
}

echo "## XSim cross-check (reduced golden set, 4w/40x32)"
run_xsim tb_hdm_decoder \
  "../../rtl/interfaces/cxl_types_pkg.sv ../../rtl/core/hdm_decoder.sv ../../rtl/core/dpa_translator.sv ../../tb/sv/tb_hdm_decoder.sv" \
  "dec_red.vec" dec
run_xsim tb_hdm_config \
  "../../rtl/interfaces/cxl_types_pkg.sv ../../rtl/csr/hdm_config.sv ../../tb/sv/tb_hdm_config.sv" \
  "cfg_red.vec" cfg
run_xsim tb_outstanding_tracker \
  "../../rtl/core/outstanding_tracker.sv ../../tb/sv/tb_outstanding_tracker.sv" \
  "ot_red.vec" ot "-d DEPTH=8 -d GENW=4 -d EPOCHW=16 -d OPW=2 -d METAW=16 -d TSW=8"
run_xsim tb_credit_manager \
  "../../rtl/core/credit_manager.sv ../../tb/sv/tb_credit_manager.sv" \
  "cm_red.vec" cm "-d NPOOLS=2 -d COUNTW=4 -d AMTW=2 -d RESETMAX=3 -d DIAGW=32"
run_xsim tb_admission_top \
  "../../rtl/core/outstanding_tracker.sv ../../rtl/core/credit_manager.sv ../../rtl/core/admission_top.sv ../../tb/sv/tb_admission_top.sv" \
  "adm_red.vec" adm "-d NPOOLS=2 -d AMTW=3 -d COUNTW=6 -d RESETMAX=8 -d DEPTH=4 -d GENW=4 -d EPOCHW=8 -d OPW=2 -d METAW=8 -d TSW=8"
run_xsim tb_control_plane_top \
  "../../rtl/core/outstanding_tracker.sv ../../rtl/core/credit_manager.sv ../../rtl/core/admission_top.sv ../../rtl/csr/config_ctrl.sv ../../rtl/core/control_plane_top.sv ../../tb/sv/tb_control_plane_top.sv" \
  "cp_red.vec" cp "-d NPOOLS=2 -d AMTW=3 -d COUNTW=6 -d RESETMAX=8 -d DEPTH=4 -d GENW=4 -d EPOCHW=8 -d OPW=2 -d METAW=8 -d TSW=8 -d HDMW=16 -d CAPW=16"
run_xsim tb_rw_scheduler \
  "../../rtl/core/rw_scheduler.sv ../../tb/sv/tb_rw_scheduler.sv" \
  "sch_red.vec" sch "-d TAGW=6 -d ADDRW=2 -d DATAW=8 -d DEPTH=4"
run_xsim tb_mem_backend \
  "../../rtl/core/mem_backend.sv ../../tb/sv/tb_mem_backend.sv" \
  "mem_red.vec" mem "-d TAGW=6 -d ADDRW=4 -d DATAW=8 -d CQD=4"
run_xsim tb_mem_subsys_top \
  "../../rtl/core/rw_scheduler.sv ../../rtl/core/mem_backend.sv ../../rtl/core/mem_subsys_top.sv ../../tb/sv/tb_mem_subsys_top.sv" \
  "msy_red.vec" msy "-d TAGW=6 -d ADDRW=2 -d DATAW=8 -d DEPTH=4 -d CQD=4"
run_xsim tb_async_fifo \
  "../../rtl/core/sync_bits.sv ../../rtl/core/async_fifo.sv ../../tb/sv/tb_async_fifo.sv" \
  "afifo_red.vec" afifo "-d WIDTHP=8 -d ADDRWP=3"

# system_top is self-checking (no vector file); run a reduced NTXN under XSim
( cd "$XD" && rm -rf xsim.dir sys_snap* 2>/dev/null
  xvlog -sv -d TAGW=6 -d ADDRW=3 -d DATAW=8 -d DEPTHP=4 -d CQDP=4 -d FAWP=2 -d NTXN=300 \
    ../../rtl/core/sync_bits.sv ../../rtl/core/async_fifo.sv ../../rtl/core/rw_scheduler.sv \
    ../../rtl/core/mem_backend.sv ../../rtl/core/mem_subsys_top.sv ../../rtl/core/system_top.sv \
    ../../tb/sv/tb_system_top.sv                                              > xvlog_sys.log 2>&1
  xelab tb_system_top -s sys_snap -timescale 1ns/1ps                         > xelab_sys.log 2>&1
  xsim sys_snap -runall                                                      > xsim_sys.log 2>&1 )
cp "$XD/xsim_sys.log" "$RAW/xsim_sys_run.log" 2>/dev/null
if grep -q "TB_RESULT: PASS" "$XD/xsim_sys.log"; then
  echo "   sys : XSim PASS ($(grep -oE 'checks=[0-9]+' "$XD/xsim_sys.log" | head -1))"
else echo "   sys : XSim FAIL"; grep -E "ERROR|TB_RESULT|Error" "$XD/xsim_sys.log" | head -5; fail=1; fi

[ $fail -eq 0 ] && echo "XSIM CROSSCHECK: PASS" || echo "XSIM CROSSCHECK: FAIL"
exit $fail
