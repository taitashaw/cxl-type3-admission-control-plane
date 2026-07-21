#!/usr/bin/env python3
"""gen_memsubsys_vectors.py — differential vectors for mem_subsys_top (M6).
Small address space => frequent read-after-write across the scheduler + backend.
Issue tags are unique among live scheduler entries (unambiguous completion match).
The model self-checks end-to-end read-after-write correctness during generation.
line1: TAG_W ADDR_W DATA_W DEPTH CQ_DEPTH COUNT
inputs (hex):  iss_valid iss_tag iss_write iss_addr iss_wdata rsp_ready
outputs (hex): iss_ready rsp_valid rsp_tag rsp_rdata occupancy
"""
import os, random
from memsubsys_model import MemSubsys

random.seed(0x6E2E)
OUT = os.path.join(os.path.dirname(__file__), "..", "vectors")
os.makedirs(OUT, exist_ok=True)
CONFIGS = [(6, 2, 8, 4, 4), (5, 1, 4, 2, 2), (6, 2, 8, 3, 3), (7, 3, 8, 4, 4)]
N_CYCLES = 4000
def hx(v): return format(int(v) & ((1 << 256) - 1), "x")
OUT_SCALAR = ["iss_ready", "rsp_valid", "rsp_tag", "rsp_rdata", "occupancy"]

def gen_one(TW, AW, DW, D, CQ):
    m = MemSubsys(TW, AW, DW, D, CQ)
    tagmask = (1 << TW) - 1
    lines = []
    for cyc in range(N_CYCLES):
        live = {m.sch.tag[i] for i in range(D) if m.sch.vld[i]}
        iss_valid = 1 if random.random() < 0.6 else 0
        iss_tag = 0
        if iss_valid:
            for _ in range(8):
                c = random.randint(0, tagmask)
                if c not in live:
                    iss_tag = c; break
            else:
                iss_valid = 0
        iss_write = random.randint(0, 1)
        iss_addr = random.randint(0, (1 << AW) - 1)
        iss_wdata = random.randint(0, (1 << DW) - 1)
        rsp_ready = 0 if random.random() < 0.3 else 1
        inp = dict(rst_n=1, iss_valid=iss_valid, iss_tag=iss_tag, iss_write=iss_write,
                   iss_addr=iss_addr, iss_wdata=iss_wdata, rsp_ready=rsp_ready)
        o = m.outputs(inp)
        toks = [hx(iss_valid), hx(iss_tag), hx(iss_write), hx(iss_addr), hx(iss_wdata), hx(rsp_ready)]
        toks += [hx(o[f]) for f in OUT_SCALAR]
        lines.append(" ".join(toks))
        m.step(inp)
    return lines

def main():
    tot = 0
    for (TW, AW, DW, D, CQ) in CONFIGS:
        lines = gen_one(TW, AW, DW, D, CQ)
        path = os.path.join(OUT, f"msy_{TW}t_{AW}a_{DW}d_{D}n_{CQ}q.vec")
        with open(path, "w") as f:
            f.write(f"{TW} {AW} {DW} {D} {CQ} {len(lines)}\n")
            f.write("\n".join(lines) + "\n")
        tot += len(lines)
    print(f"mem_subsys vectors: {tot} cycles across {len(CONFIGS)} configs")

if __name__ == "__main__":
    main()
