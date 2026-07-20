#!/usr/bin/env python3
"""
gen_scheduler_vectors.py — differential vectors for rw_scheduler (M5) from the
independent Scheduler model. A small address space forces same-address hazards so
the per-address ordering interlock and cross-address reordering are exercised.
Memory completions target only ISSUED, not-done entries (environment assumption);
issue tags are kept unique across live entries so completion matching is unambiguous.

line1: TAG_W ADDR_W DATA_W DEPTH COUNT
inputs (hex): iss_valid iss_tag iss_write iss_addr iss_wdata mem_ready mc_valid mc_tag mc_rdata rsp_ready
outputs(hex): iss_ready mem_valid mem_tag mem_write mem_addr mem_wdata rsp_valid rsp_tag rsp_rdata occupancy
"""
import os, random
from scheduler_model import Scheduler

random.seed(0x5CED)
OUT = os.path.join(os.path.dirname(__file__), "..", "vectors")
os.makedirs(OUT, exist_ok=True)

# (TAG_W, ADDR_W, DATA_W, DEPTH)
CONFIGS = [(6, 2, 8, 4), (5, 1, 4, 2), (6, 2, 8, 3), (7, 3, 8, 5)]
N_CYCLES = 4000

def hx(v): return format(int(v) & ((1 << 256) - 1), "x")

OUT_SCALAR = ["iss_ready", "mem_valid", "mem_tag", "mem_write", "mem_addr", "mem_wdata",
              "rsp_valid", "rsp_tag", "rsp_rdata", "occupancy"]

def gen_one(TAG_W, ADDR_W, DATA_W, DEPTH):
    m = Scheduler(TAG_W, ADDR_W, DATA_W, DEPTH)
    tagmask = (1 << TAG_W) - 1
    lines = []
    for cyc in range(N_CYCLES):
        live_tags = {m.tag[i] for i in range(DEPTH) if m.vld[i]}
        # unique issue tag not currently live
        iss_valid = 1 if random.random() < 0.6 else 0
        iss_tag = 0
        if iss_valid:
            for _ in range(8):
                cand = random.randint(0, tagmask)
                if cand not in live_tags:
                    iss_tag = cand
                    break
            else:
                iss_valid = 0
        iss_write = random.randint(0, 1)
        iss_addr = random.randint(0, (1 << ADDR_W) - 1)
        iss_wdata = random.randint(0, (1 << DATA_W) - 1)
        mem_ready = 0 if random.random() < 0.3 else 1
        rsp_ready = 0 if random.random() < 0.3 else 1
        # completion: pick an issued-not-done entry to complete
        issd_nd = [i for i in range(DEPTH) if m.vld[i] and m.issd[i] and not m.done[i]]
        if issd_nd and random.random() < 0.55:
            sl = random.choice(issd_nd)
            mc_valid = 1; mc_tag = m.tag[sl]; mc_rdata = random.randint(0, (1 << DATA_W) - 1)
        else:
            mc_valid = 0; mc_tag = 0; mc_rdata = 0

        inp = dict(rst_n=1, iss_valid=iss_valid, iss_tag=iss_tag, iss_write=iss_write,
                   iss_addr=iss_addr, iss_wdata=iss_wdata, mem_ready=mem_ready,
                   mc_valid=mc_valid, mc_tag=mc_tag, mc_rdata=mc_rdata, rsp_ready=rsp_ready)
        o = m.outputs(inp)
        toks = [hx(iss_valid), hx(iss_tag), hx(iss_write), hx(iss_addr), hx(iss_wdata),
                hx(mem_ready), hx(mc_valid), hx(mc_tag), hx(mc_rdata), hx(rsp_ready)]
        toks += [hx(o[f]) for f in OUT_SCALAR]
        lines.append(" ".join(toks))
        m.step(inp)
    return lines

def main():
    tot = 0
    for (TW, AW, DW, D) in CONFIGS:
        lines = gen_one(TW, AW, DW, D)
        path = os.path.join(OUT, f"sch_{TW}t_{AW}a_{DW}d_{D}n.vec")
        with open(path, "w") as f:
            f.write(f"{TW} {AW} {DW} {D} {len(lines)}\n")
            f.write("\n".join(lines) + "\n")
        tot += len(lines)
    print(f"scheduler vectors: {tot} cycles across {len(CONFIGS)} configs")

if __name__ == "__main__":
    main()
