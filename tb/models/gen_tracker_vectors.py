#!/usr/bin/env python3
"""
gen_tracker_vectors.py — differential vectors for outstanding_tracker from the
independent model. Each line is one cycle: inputs then expected sampled outputs.
Deterministic (fixed seed). Exercises alloc/retire/reclaim/timeout, full/empty,
same-cycle alloc+retire, generation wrap, timestamp wrap, and the stale/non-live/
invalid response classes.

File: tracker_<DEPTH>d_<GEN>g.vec
  line1: DEPTH GEN_W EPOCH_W OP_W META_W TS_W COUNT
  each line (hex): current_ts timeout_thresh alloc_req alloc_epoch alloc_op alloc_meta
                   resp_valid resp_tag reclaim_req reclaim_slot |
                   alloc_gnt alloc_tag alloc_slot full resp_retire resp_class
                   retired_epoch retired_op retired_meta reclaim_done occupancy
                   high_watermark timeout_any alloc_count retire_count full_count
                   timeout_count invalid_slot_count non_live_count stale_gen_count
                   err_sticky err_first_class
"""
import os, random
from tracker_model import Tracker

random.seed(0x0757ACC)
OUT = os.path.join(os.path.dirname(__file__), "..", "vectors")
os.makedirs(OUT, exist_ok=True)

# (DEPTH, GEN_W): non-power-of-two (3,7), small/large depth, small gen (wrap)
CONFIGS = [(1,2),(2,4),(3,2),(4,4),(7,2),(8,4),(16,4)]
EPOCH_W, OP_W, META_W, TS_W = 16, 2, 16, 8
N_CYCLES = 4000
THRESH = 24     # < 2^(TS_W-1)=128

def hx(v): return format(int(v) & ((1<<256)-1), "x")

OUTFIELDS = ["alloc_gnt","alloc_tag","alloc_slot","full","resp_retire","resp_class",
             "retired_epoch","retired_op","retired_meta","reclaim_done","reclaim_class","occupancy",
             "high_watermark","quarantined_count","timeout_any","timeout_cfg_bad",
             "alloc_count","retire_count","full_count","timeout_count","reclaim_count",
             "invalid_slot_count","non_live_count","stale_gen_count",
             "err_sticky","err_first_class"]

def gen_one(DEPTH, GEN_W):
    m = Tracker(DEPTH, GEN_W, EPOCH_W, OP_W, META_W, TS_W)
    granted = []          # (tag, slot) history for crafting responses
    ts = 0
    lines = []
    half = 1 << (TS_W-1)
    for cyc in range(N_CYCLES):
        # advance timestamp (sometimes jump to force timeouts / ts-wrap)
        ts = (ts + random.choice([0,1,1,1,2,5, THRESH+3, (1<<(TS_W-1))+5])) & ((1<<TS_W)-1)  # incl. big jump to age past an out-of-range threshold
        # vary threshold: mostly valid, sometimes disabled(0) or out-of-range(>=half)
        rt = random.random()
        thr = THRESH if rt < 0.8 else (0 if rt < 0.9 else (half + random.randint(0, half-1)) & ((1<<TS_W)-1))
        alloc_req = 1 if random.random() < 0.55 else 0
        alloc_epoch = random.randint(0, (1<<EPOCH_W)-1)
        alloc_op = random.randint(0, (1<<OP_W)-1)
        alloc_meta = random.randint(0, (1<<META_W)-1)

        resp_valid = 1 if random.random() < 0.45 else 0
        resp_tag = 0
        if resp_valid:
            r = random.random()
            if granted and r < 0.6:
                resp_tag = random.choice(granted)[0]          # likely valid/stale
            elif granted and r < 0.75:
                tag, slot = random.choice(granted)            # corrupt generation -> stale
                gbits = (random.randint(1,(1<<GEN_W)-1) << m.SLOT_W)
                resp_tag = (tag ^ gbits)
            elif r < 0.88:
                resp_tag = random.randint(0, (1<<m.TAG_W)-1)  # random -> non_live/stale
            else:
                bad_slot = DEPTH + random.randint(0, max(1,(1<<m.SLOT_W)-DEPTH))
                bad_slot &= (1<<m.SLOT_W)-1
                resp_tag = (random.randint(0,(1<<GEN_W)-1) << m.SLOT_W) | bad_slot  # maybe invalid slot

        reclaim_req = 1 if random.random() < 0.15 else 0
        # composite reclaim tag: often a real granted tag (hits OK / NOT_QUARANTINED),
        # sometimes gen-corrupted (STALE_GEN) or random (NOT_LIVE / INVALID_SLOT)
        rr = random.random()
        if granted and rr < 0.55:
            reclaim_tag = random.choice(granted)[0]
        elif granted and rr < 0.7:
            t, _sl = random.choice(granted)
            reclaim_tag = t ^ (random.randint(1,(1<<GEN_W)-1) << m.SLOT_W)
        else:
            reclaim_tag = random.randint(0, (1<<m.TAG_W)-1)

        inp = dict(current_ts=ts, timeout_thresh=thr, alloc_req=alloc_req,
                   alloc_epoch=alloc_epoch, alloc_op=alloc_op, alloc_meta=alloc_meta,
                   resp_valid=resp_valid, resp_tag=resp_tag,
                   reclaim_req=reclaim_req, reclaim_tag=reclaim_tag)
        o = m.outputs(inp)
        if o["alloc_gnt"]:
            granted.append((o["alloc_tag"], o["alloc_slot"]))
            if len(granted) > 64: granted.pop(0)
        toks = [hx(ts),hx(thr),hx(alloc_req),hx(alloc_epoch),hx(alloc_op),hx(alloc_meta),
                hx(resp_valid),hx(resp_tag),hx(reclaim_req),hx(reclaim_tag)]
        toks += [hx(o[f]) for f in OUTFIELDS]
        lines.append(" ".join(toks))
        m.step(inp)
    return m, lines

def main():
    tot=0; stats=dict(retire=0,invalid=0,non_live=0,stale=0,timeout=0,full=0)
    for (D,G) in CONFIGS:
        m, lines = gen_one(D, G)
        for k in stats: stats[k]+=m.c[{'retire':'retire','invalid':'invalid','non_live':'non_live','stale':'stale','timeout':'timeout','full':'full'}[k]]
        path=os.path.join(OUT, f"tracker_{D}d_{G}g.vec")
        with open(path,"w") as f:
            f.write(f"{D} {G} {EPOCH_W} {OP_W} {META_W} {TS_W} {len(lines)}\n")
            f.write("\n".join(lines)+"\n")
        tot+=len(lines)
    print(f"tracker vectors: {tot} cycles across {len(CONFIGS)} configs")
    print(f"  cumulative model counters: {stats}")

if __name__ == "__main__":
    main()
