#!/usr/bin/env bash
# run_qemu_replay.sh — M8 SOFTWARE_EMULATED lane. Capture real CXL Type-3 windows
# from QEMU 8.2.2, replay them against the hdm_decoder + hdm_config RTL on both
# toolchains. If QEMU cannot instantiate the topology, reports BLOCKED (never
# fabricates a capture).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RAW=evidence/raw; Q=sw/qemu_cxl; mkdir -p "$RAW"
DEFS="-DNWIN=4 -DHPAW=40 -DDPAW=32"
fail=0

command -v qemu-system-x86_64 >/dev/null || { echo "QEMU REPLAY: BLOCKED (qemu-system-x86_64 not found)"; exit 3; }
echo "## capture real CXL Type-3 windows from QEMU $(qemu-system-x86_64 --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
( cd "$Q"
  bash capture.sh 256M 256M cap_256_256
  bash capture.sh 1G   256M cap_1g_256
  bash capture.sh 512M 512M cap_512_512 ) | sed 's/^/   /'
if ! ls "$Q"/cap_*.json >/dev/null 2>&1; then
  echo "QEMU REPLAY: BLOCKED (no captures produced; see $Q/*.mtree.log)"; exit 2
fi
echo "## translate captures -> replay vectors"
( cd "$Q" && python3 gen_replay_vectors.py ) | sed 's/^/   /'

run() { # tb vec tag
  local tb=$1 vec=$2 tag=$3
  iverilog -g2012 $DEFS -c "sim/filelists/tb_${tb}.f" -o "sim/icarus/q_${tag}.vvp" >"$RAW/icarus_q_${tag}_c.log" 2>&1 \
    && vvp "sim/icarus/q_${tag}.vvp" +VEC="$vec" > "$RAW/icarus_q_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/icarus_q_${tag}_run.log" && ip=PASS || { ip=FAIL; fail=1; }
  rm -rf "sim/verilator/obj_q_${tag}"
  verilator --binary --timing -Wno-fatal $DEFS -f "sim/filelists/tb_${tb}.f" \
    --Mdir "sim/verilator/obj_q_${tag}" --top-module "tb_${tb}" -o "q_${tag}" >"$RAW/verilator_q_${tag}_b.log" 2>&1
  local bin; bin=$(ls "sim/verilator/obj_q_${tag}/q_${tag}" "sim/verilator/obj_q_${tag}/Vtb_${tb}" 2>/dev/null | head -1)
  [ -x "$bin" ] && "$bin" +VEC="$vec" > "$RAW/verilator_q_${tag}_run.log" 2>&1
  grep -q "TB_RESULT: PASS" "$RAW/verilator_q_${tag}_run.log" && vp=PASS || { vp=FAIL; fail=1; }
  printf "   %-16s icarus=%-4s verilator=%-4s\n" "$tag" "$ip" "$vp"
}
mkdir -p sim/icarus sim/verilator
echo "## replay vs RTL (two-toolchain)"
run hdm_decoder tb/vectors/dec_qemu_replay.vec dec_qemu
run hdm_config  tb/vectors/cfg_qemu_replay.vec cfg_qemu
echo "=================================================="
[ $fail -eq 0 ] && echo "QEMU REPLAY: PASS (real CXL Type-3 windows agree with RTL decode/config)" || echo "QEMU REPLAY: FAIL"
exit $fail
