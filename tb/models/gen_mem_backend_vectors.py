#!/usr/bin/env python3
"""gen_mem_backend_vectors.py — differential vectors for mem_backend (M6).
Small address space => frequent read-after-write to the same address.
line1: TAG_W ADDR_W DATA_W CQ_DEPTH COUNT
inputs (hex):  req_valid req_tag req_write req_addr req_wdata cmp_ready
outputs (hex): req_ready cmp_valid cmp_tag cmp_rdata
"""
import os, random
from mem_backend_model import MemBackend

random.seed(0x6DD2)
OUT = os.path.join(os.path.dirname(__file__), "..", "vectors")
os.makedirs(OUT, exist_ok=True)
CONFIGS = [(6, 4, 8, 4), (5, 2, 4, 2), (6, 3, 8, 3), (7, 2, 8, 8)]
N_CYCLES = 4000
def hx(v): return format(int(v) & ((1 << 256) - 1), "x")
OUT_SCALAR = ["req_ready", "cmp_valid", "cmp_tag", "cmp_rdata"]

def gen_one(TW, AW, DW, CQ):
    m = MemBackend(TW, AW, DW, CQ)
    lines = []
    for cyc in range(N_CYCLES):
        req_valid = 1 if random.random() < 0.7 else 0
        req_tag   = random.randint(0, (1 << TW) - 1)
        req_write = 1 if random.random() < 0.5 else 0
        req_addr  = random.randint(0, (1 << AW) - 1)
        req_wdata = random.randint(0, (1 << DW) - 1)
        cmp_ready = 0 if random.random() < 0.3 else 1
        inp = dict(rst_n=1, req_valid=req_valid, req_tag=req_tag, req_write=req_write,
                   req_addr=req_addr, req_wdata=req_wdata, cmp_ready=cmp_ready)
        o = m.outputs(inp)
        toks = [hx(req_valid), hx(req_tag), hx(req_write), hx(req_addr), hx(req_wdata), hx(cmp_ready)]
        toks += [hx(o[f]) for f in OUT_SCALAR]
        lines.append(" ".join(toks))
        m.step(inp)
    return lines

def main():
    tot = 0
    for (TW, AW, DW, CQ) in CONFIGS:
        lines = gen_one(TW, AW, DW, CQ)
        path = os.path.join(OUT, f"mem_{TW}t_{AW}a_{DW}d_{CQ}q.vec")
        with open(path, "w") as f:
            f.write(f"{TW} {AW} {DW} {CQ} {len(lines)}\n")
            f.write("\n".join(lines) + "\n")
        tot += len(lines)
    print(f"mem_backend vectors: {tot} cycles across {len(CONFIGS)} configs")

if __name__ == "__main__":
    main()
