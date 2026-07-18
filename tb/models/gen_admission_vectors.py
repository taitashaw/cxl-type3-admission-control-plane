#!/usr/bin/env python3
"""
gen_admission_vectors.py — differential vectors for admission_top from the
independent Admission model. One line = one cycle: inputs then sampled outputs.
Deterministic. Exercises accept/reject (by enable, credit, tracker-full, issue
buffer), retirement, reclaim, SIMULTANEOUS retire+reclaim on different slots
(dual return to the same pool), issue-buffer backpressure and reclaim backpressure.

line1: N_POOLS AMT_W COUNT_W RESET_MAX DEPTH GEN_W EPOCH_W OP_W META_W TS_W COUNT
inputs  (hex): current_ts timeout_enable timeout_thresh active_epoch req_valid
               req_accept_enable req_op req_meta req_credit_vec downstream_ready
               resp_valid resp_tag reclaim_req_valid reclaim_tag reclaim_rsp_ready
outputs (hex): see OUT_SCALAR below, then used[0..N-1] then available[0..N-1]
"""
import os, random
from admission_model import Admission

random.seed(0x4D4)
OUT = os.path.join(os.path.dirname(__file__), "..", "vectors")
os.makedirs(OUT, exist_ok=True)

# (N_POOLS, AMT_W, COUNT_W, RESET_MAX, DEPTH, GEN_W): small, non-power-of-two depth
CONFIGS = [
    (2, 3, 6, 8, 4, 4),
    (1, 2, 4, 3, 3, 2),
    (3, 2, 5, 6, 5, 3),
    (2, 4, 7, 12, 8, 4),
]
EPOCH_W, OP_W, META_W, TS_W = 8, 2, 8, 8
N_CYCLES = 4000
THRESH = 24

def hx(v): return format(int(v) & ((1 << 256) - 1), "x")

OUT_SCALAR = ["req_ready", "req_accept", "tracker_alloc_fire", "credit_consume_fire",
              "issue_enqueue", "issue_valid", "issued_tag", "issue_tag",
              "resp_retire", "resp_class", "reclaim_req_ready", "reclaim_rsp_valid",
              "reclaim_rsp_tag", "reclaim_rsp_class", "credit_return_valid",
              "credit_return_accepted", "occupancy", "retired_epoch"]

def gen_one(N_POOLS, AMT_W, COUNT_W, RESET_MAX, DEPTH, GEN_W):
    m = Admission(N_POOLS, AMT_W, COUNT_W, RESET_MAX, DEPTH, GEN_W, EPOCH_W, OP_W, META_W, TS_W)
    amask = (1 << AMT_W) - 1
    granted = []
    ts = 0
    lines = []
    half = 1 << (TS_W - 1)
    SLOT_W = m.trk.SLOT_W
    TAG_W = m.trk.TAG_W
    for cyc in range(N_CYCLES):
        ts = (ts + random.choice([0, 1, 1, 1, 2, 5, THRESH + 3, half + 5])) & ((1 << TS_W) - 1)
        rt = random.random()
        to_en = 0 if rt < 0.12 else 1
        thr = THRESH if rt < 0.85 else random.randint(1, half - 1)
        active_epoch = random.randint(0, (1 << EPOCH_W) - 1)
        req_valid = 1 if random.random() < 0.6 else 0
        req_accept_enable = 0 if random.random() < 0.15 else 1     # exercise A2
        req_op = random.randint(0, (1 << OP_W) - 1)
        req_meta = random.randint(0, (1 << META_W) - 1)
        # per-pool credit request: mostly small so many fit; sometimes large/illegal
        cv = 0
        for p in range(N_POOLS):
            amt = random.choice([0, 0, 1, 1, 2, amask])
            cv |= (amt & amask) << (p * AMT_W)
        req_credit_vec = cv
        downstream_ready = 0 if random.random() < 0.3 else 1        # issue-buffer backpressure

        resp_valid = 1 if random.random() < 0.4 else 0
        resp_tag = 0
        if resp_valid:
            r = random.random()
            if granted and r < 0.6:
                resp_tag = random.choice(granted)[0]
            elif granted and r < 0.75:
                tag, _sl = random.choice(granted)
                resp_tag = tag ^ (random.randint(1, (1 << GEN_W) - 1) << SLOT_W)
            elif r < 0.88:
                resp_tag = random.randint(0, (1 << TAG_W) - 1)
            else:
                bad = DEPTH + random.randint(0, max(1, (1 << SLOT_W) - DEPTH))
                resp_tag = (random.randint(0, (1 << GEN_W) - 1) << SLOT_W) | (bad & ((1 << SLOT_W) - 1))

        # land a valid retire exactly as an entry crosses the threshold
        if to_en and random.random() < 0.14:
            cands = [x for x in range(DEPTH) if m.trk.live[x] and not m.trk.timed[x]]
            if cands:
                sl = random.choice(cands)
                ts = (m.trk.issue_ts[sl] + thr) & ((1 << TS_W) - 1)
                resp_valid = 1
                resp_tag = (m.trk.gen[sl] << SLOT_W) | sl

        reclaim_req_valid = 1 if random.random() < 0.15 else 0
        reclaim_rsp_ready = 0 if random.random() < 0.25 else 1
        rr = random.random()
        if granted and rr < 0.55:
            reclaim_tag = random.choice(granted)[0]
        elif granted and rr < 0.7:
            t, _sl = random.choice(granted)
            reclaim_tag = t ^ (random.randint(1, (1 << GEN_W) - 1) << SLOT_W)
        else:
            reclaim_tag = random.randint(0, (1 << TAG_W) - 1)

        # TARGETED non-quarantined reclaim (exercise RCL_NOT_QUARANTINED)
        if m.trk.rr_valid == 0 and random.random() < 0.1:
            nq = [x for x in range(DEPTH) if m.trk.live[x] and not m.trk.timed[x]]
            if nq:
                sl = random.choice(nq)
                reclaim_req_valid = 1
                reclaim_tag = (m.trk.gen[sl] << SLOT_W) | sl

        # TARGETED DUAL COMMIT: valid retire on slot X + successful reclaim on a
        # DIFFERENT quarantined slot Y -> both credit vectors return this cycle.
        if m.trk.rr_valid == 0 and random.random() < 0.12:
            live_nt = [x for x in range(DEPTH) if m.trk.live[x] and not m.trk.timed[x]]
            live_q = [x for x in range(DEPTH) if m.trk.live[x] and m.trk.timed[x]]
            pair = [(x, y) for x in live_nt for y in live_q if x != y]
            if pair:
                # prefer a pair whose per-pool credit sum exceeds 2^AMT_W-1 so the
                # AMT_W+1 dual-return widening is exercised (truncation observable)
                def povr(px, py):
                    return max((m._vec_pool(m.trk.credit_vec[px], p)
                                + m._vec_pool(m.trk.credit_vec[py], p)) > amask
                               for p in range(N_POOLS))
                over = [pr for pr in pair if povr(*pr)]
                x, y = random.choice(over) if over else random.choice(pair)
                resp_valid = 1
                resp_tag = (m.trk.gen[x] << SLOT_W) | x        # retire X
                reclaim_req_valid = 1
                reclaim_tag = (m.trk.gen[y] << SLOT_W) | y     # reclaim Y (quarantined)

        inp = dict(rst_n=1, current_ts=ts, timeout_enable=to_en, timeout_thresh=thr,
                   active_epoch=active_epoch, req_valid=req_valid,
                   req_accept_enable=req_accept_enable, req_op=req_op, req_meta=req_meta,
                   req_credit_vec=req_credit_vec, downstream_ready=downstream_ready,
                   resp_valid=resp_valid, resp_tag=resp_tag,
                   reclaim_req_valid=reclaim_req_valid, reclaim_tag=reclaim_tag,
                   reclaim_rsp_ready=reclaim_rsp_ready)
        o = m.outputs(inp)
        if o["tracker_alloc_fire"]:
            granted.append((o["issued_tag"], o["issued_tag"] & ((1 << SLOT_W) - 1)))
            if len(granted) > 64:
                granted.pop(0)
        toks = [hx(ts), hx(to_en), hx(thr), hx(active_epoch), hx(req_valid),
                hx(req_accept_enable), hx(req_op), hx(req_meta), hx(req_credit_vec),
                hx(downstream_ready), hx(resp_valid), hx(resp_tag), hx(reclaim_req_valid),
                hx(reclaim_tag), hx(reclaim_rsp_ready)]
        toks += [hx(o[f]) for f in OUT_SCALAR]
        toks += [hx(o["used"][p]) for p in range(N_POOLS)]
        toks += [hx(o["available"][p]) for p in range(N_POOLS)]
        lines.append(" ".join(toks))
        m.step(inp)
    return lines

def main():
    tot = 0
    for (NP, AW, CW, RM, D, G) in CONFIGS:
        lines = gen_one(NP, AW, CW, RM, D, G)
        path = os.path.join(OUT, f"adm_{NP}p_{AW}a_{CW}c_{RM}m_{D}d_{G}g.vec")
        with open(path, "w") as f:
            f.write(f"{NP} {AW} {CW} {RM} {D} {G} {EPOCH_W} {OP_W} {META_W} {TS_W} {len(lines)}\n")
            f.write("\n".join(lines) + "\n")
        tot += len(lines)
    print(f"admission vectors: {tot} cycles across {len(CONFIGS)} configs")

if __name__ == "__main__":
    main()
