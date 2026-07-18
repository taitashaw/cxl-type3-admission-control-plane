#!/usr/bin/env python3
"""
gen_tracker_vectors.py — differential vectors for outstanding_tracker from the
independent model. Each line is one cycle: inputs then expected sampled outputs.
Deterministic (fixed seed). Exercises alloc/retire/reclaim/timeout, full/empty,
same-cycle alloc+retire, generation wrap, timestamp wrap, and the stale/non-live/
invalid response classes.

File: tracker_<DEPTH>d_<GEN>g.vec
  line1: DEPTH GEN_W EPOCH_W OP_W META_W TS_W CREDIT_W COUNT
  each line (hex): <input tokens...> <output tokens...>
    inputs  = current_ts timeout_enable timeout_thresh alloc_req alloc_epoch
              alloc_op alloc_meta alloc_credit_vec resp_valid resp_tag
              reclaim_req_valid reclaim_tag reclaim_rsp_ready
    outputs = see OUTFIELDS below (registered reclaim response, combinational
              retire/reclaim commit sidebands, occupancy/counters/diagnostics)
"""
import os, random
from tracker_model import Tracker

random.seed(0x0757ACC)
OUT = os.path.join(os.path.dirname(__file__), "..", "vectors")
os.makedirs(OUT, exist_ok=True)

# (DEPTH, GEN_W): non-power-of-two (3,7), small/large depth, small gen (wrap)
CONFIGS = [(1,2),(2,4),(3,2),(4,4),(7,2),(8,4),(16,4)]
EPOCH_W, OP_W, META_W, TS_W, CREDIT_W = 16, 2, 16, 8, 16
N_CYCLES = 4000
THRESH = 24     # < 2^(TS_W-1)=128

def hx(v): return format(int(v) & ((1<<256)-1), "x")

OUTFIELDS = ["alloc_gnt","alloc_tag","alloc_slot","full","resp_retire","resp_class",
             "retired_epoch","retired_op","retired_meta","reclaim_req_ready","reclaim_rsp_valid","reclaim_rsp_tag","reclaim_rsp_class","reclaim_rsp_meta",
             "retire_commit_fire","retire_commit_credit_vec","retire_commit_epoch","retire_commit_meta",
             "reclaim_commit_fire","reclaim_commit_credit_vec","reclaim_commit_epoch","reclaim_commit_meta","occupancy",
             "high_watermark","quarantined_count","timeout_any",
             "alloc_count","retire_count","full_count","timeout_count","reclaim_count",
             "invalid_slot_count","non_live_count","stale_gen_count",
             "err_sticky","err_first_class"]

def gen_one(DEPTH, GEN_W):
    m = Tracker(DEPTH, GEN_W, EPOCH_W, OP_W, META_W, TS_W, CREDIT_W)
    granted = []          # (tag, slot) history for crafting responses
    ts = 0
    lines = []
    half = 1 << (TS_W-1)
    for cyc in range(N_CYCLES):
        # advance timestamp (sometimes jump to force timeouts / ts-wrap)
        ts = (ts + random.choice([0,1,1,1,2,5, THRESH+3, (1<<(TS_W-1))+5])) & ((1<<TS_W)-1)  # incl. big jump to age past an out-of-range threshold
        # vary threshold: mostly valid, sometimes disabled(0) or out-of-range(>=half)
        # committed timeout config (validated upstream by hdm_config): enable + legal threshold
        rt = random.random()
        to_en = 0 if rt < 0.12 else 1
        thr   = THRESH if rt < 0.85 else random.randint(1, half-1)
        alloc_req = 1 if random.random() < 0.55 else 0
        alloc_epoch = random.randint(0, (1<<EPOCH_W)-1)
        alloc_op = random.randint(0, (1<<OP_W)-1)
        alloc_meta = random.randint(0, (1<<META_W)-1)
        alloc_credit_vec = random.randint(0, (1<<CREDIT_W)-1)

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

        # TARGETED: land a VALID retire on the exact cycle a live entry's age
        # first crosses the threshold -- the only window where the
        # timeout-vs-retire priority rule is observable.
        if to_en and random.random() < 0.14:
            cands = [x for x in range(DEPTH) if m.live[x] and not m.timed[x]]
            if cands:
                sl = random.choice(cands)
                ts = (m.issue_ts[sl] + thr) & ((1<<TS_W)-1)   # age == thr exactly
                resp_valid = 1
                resp_tag = (m.gen[sl] << m.SLOT_W) | sl       # valid tag -> VALID retire

        reclaim_req_valid = 1 if random.random() < 0.15 else 0
        reclaim_rsp_ready = 0 if random.random() < 0.25 else 1   # backpressure the response 25%
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

        # TARGETED: reclaim a live, matching-gen, NON-quarantined slot on a cycle
        # the channel can accept (model not already holding a response). This is
        # the only stimulus that exercises the RCL_NOT_QUARANTINED refusal -- the
        # recovery contract that a reclaim must NOT free a slot that never timed
        # out. (Without it the "reclaim needs quarantine" mutation is unobservable.)
        if m.rr_valid == 0 and random.random() < 0.12:
            nq = [x for x in range(DEPTH) if m.live[x] and not m.timed[x]]
            if nq:
                sl = random.choice(nq)
                reclaim_req_valid = 1
                reclaim_tag = (m.gen[sl] << m.SLOT_W) | sl

        # TARGETED: RCL_SUPERSEDED -- an otherwise-qualified reclaim (live, matching
        # generation, ALREADY quarantined) that collides with a valid same-slot
        # retirement on the accept cycle. The response wins; the reclaim must be a
        # no-op. Only meaningful when the channel can accept (no response pending).
        if m.rr_valid == 0 and random.random() < 0.10:
            q = [x for x in range(DEPTH) if m.live[x] and m.timed[x]]
            if q:
                sl = random.choice(q)
                vtag = (m.gen[sl] << m.SLOT_W) | sl
                reclaim_req_valid = 1; reclaim_tag = vtag
                resp_valid = 1; resp_tag = vtag        # valid same-slot retire -> SUPERSEDED

        inp = dict(current_ts=ts, timeout_enable=to_en, timeout_thresh=thr, alloc_req=alloc_req,
                   alloc_epoch=alloc_epoch, alloc_op=alloc_op, alloc_meta=alloc_meta,
                   alloc_credit_vec=alloc_credit_vec,
                   resp_valid=resp_valid, resp_tag=resp_tag,
                   reclaim_req_valid=reclaim_req_valid, reclaim_tag=reclaim_tag,
                   reclaim_rsp_ready=reclaim_rsp_ready)
        o = m.outputs(inp)
        if o["alloc_gnt"]:
            granted.append((o["alloc_tag"], o["alloc_slot"]))
            if len(granted) > 64: granted.pop(0)
        toks = [hx(ts),hx(to_en),hx(thr),hx(alloc_req),hx(alloc_epoch),hx(alloc_op),hx(alloc_meta),hx(alloc_credit_vec),
                hx(resp_valid),hx(resp_tag),hx(reclaim_req_valid),hx(reclaim_tag),hx(reclaim_rsp_ready)]
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
            f.write(f"{D} {G} {EPOCH_W} {OP_W} {META_W} {TS_W} {CREDIT_W} {len(lines)}\n")
            f.write("\n".join(lines)+"\n")
        tot+=len(lines)
    print(f"tracker vectors: {tot} cycles across {len(CONFIGS)} configs")
    print(f"  cumulative model counters: {stats}")

if __name__ == "__main__":
    main()
