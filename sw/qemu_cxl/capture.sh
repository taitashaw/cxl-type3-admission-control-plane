#!/usr/bin/env bash
# capture.sh — SOFTWARE_EMULATED lane (M8). Instantiate a REAL QEMU 8.2.2 CXL
# Type-3 memory-expander topology and capture the actual HPA CXL Fixed Memory
# Window (CFMW) and the device DPA capacity that QEMU sets up. No fabrication:
# if QEMU cannot instantiate the topology, this prints BLOCKED with the error.
# Usage: capture.sh <fmw_size> <mem_size> <out_prefix>
set -u
FMW=${1:-4G}; MEM=${2:-256M}; OUT=${3:-cap}
QEMU=qemu-system-x86_64
command -v "$QEMU" >/dev/null || { echo "BLOCKED: $QEMU not found"; exit 3; }

RAW="${OUT}.mtree.log"
printf 'info mtree -f\nquit\n' | timeout 60 "$QEMU" \
  -machine q35,cxl=on -m 2G,maxmem=8G,slots=8 \
  -object memory-backend-ram,id=cxl-mem1,size=$MEM \
  -object memory-backend-ram,id=lsa1,size=$MEM \
  -device pxb-cxl,bus_nr=12,id=cxl.1,bus=pcie.0 \
  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2 \
  -device cxl-type3,bus=rp0,volatile-memdev=cxl-mem1,id=cxl-vmem0,lsa=lsa1 \
  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=$FMW \
  -S -display none -serial null -monitor stdio > "$RAW" 2>&1

if grep -qiE "error|cannot|could not|invalid" "$RAW" && ! grep -q "cxl-fixed-memory-region" "$RAW"; then
  echo "BLOCKED: QEMU CXL Type-3 topology failed (fmw=$FMW mem=$MEM)"
  grep -iE "error|cannot|could not|invalid" "$RAW" | head -3
  exit 2
fi

# extract the CFMW HPA range and the cxl-mem1 (DPA) range from the memory tree
python3 - "$RAW" "$OUT" <<'PY'
import sys, re, json
raw, out = sys.argv[1], sys.argv[2]
txt = open(raw).read()
def rng(pat):
    m = re.search(r'([0-9a-f]{16})-([0-9a-f]{16}) \(prio \d+, [^)]*\): '+pat, txt)
    return (int(m.group(1),16), int(m.group(2),16)) if m else None
fmw = rng('cxl-fixed-memory-region')
dpa = rng('cxl-mem1')
if not fmw or not dpa:
    print("BLOCKED: could not parse CFMW/DPA from mtree"); sys.exit(2)
cap = {
  "source": "QEMU 8.2.2 cxl-type3 (SOFTWARE_EMULATED)",
  "hpa_base": fmw[0], "hpa_end": fmw[1], "hpa_size": fmw[1]-fmw[0]+1,
  "dpa_base": dpa[0], "dpa_end": dpa[1], "dpa_size": dpa[1]-dpa[0]+1,
}
json.dump(cap, open(out+".json","w"), indent=2)
print(f"CAPTURED hpa=[{fmw[0]:#x},{fmw[1]:#x}] size={cap['hpa_size']:#x} "
      f"dpa_size={cap['dpa_size']:#x} -> {out}.json")
PY
