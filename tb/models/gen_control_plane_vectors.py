#!/usr/bin/env python3
"""
gen_control_plane_vectors.py — differential vectors for control_plane_top (Phase 2c)
from the independent ControlPlane model. Exercises admission traffic, config
accept -> freeze -> drain -> shared commit -> OK, invalid config (no commit),
config while traffic is live, and response backpressure.

line1: N_POOLS AMT_W COUNT_W RESET_MAX DEPTH GEN_W EPOCH_W OP_W META_W TS_W HDM_W CAP_W COUNT
inputs (hex): current_ts cfg_req_valid cfg_hdm_base cfg_hdm_size cfg_capacity
              cfg_timeout_en cfg_timeout_thresh cfg_cmax cfg_epoch cfg_rsp_ready
              req_valid req_op req_meta req_credit_vec downstream_ready
              resp_valid resp_tag reclaim_req_valid reclaim_tag reclaim_rsp_ready
outputs (hex): scalars (see OUT_SCALAR) then used[0..N-1] then available[0..N-1]
"""
import os, random
from config_model import ControlPlane, S_DRAIN

random.seed(0x2C0FFEE)
OUT = os.path.join(os.path.dirname(__file__), "..", "vectors")
os.makedirs(OUT, exist_ok=True)

# (N_POOLS, AMT_W, COUNT_W, RESET_MAX, DEPTH, GEN_W)
CONFIGS = [
    (2, 3, 6, 8, 4, 4),
    (1, 2, 4, 3, 3, 2),
    (3, 2, 5, 6, 5, 3),
    (2, 4, 7, 12, 2, 4),
]
EPOCH_W, OP_W, META_W, TS_W, HDM_W, CAP_W = 8, 2, 8, 8, 16, 16
N_CYCLES = 4000
THRESH = 24

def hx(v): return format(int(v) & ((1 << 256) - 1), "x")

OUT_SCALAR = ["cfg_req_ready", "cfg_rsp_valid", "cfg_rsp_code", "cfg_rsp_reason",
              "req_ready", "req_accept", "issued_tag", "issue_valid", "issue_tag",
              "resp_retire", "resp_class", "retired_epoch", "reclaim_req_ready",
              "reclaim_rsp_valid", "reclaim_rsp_tag", "reclaim_rsp_class",
              "global_cfg_commit_fire", "active_epoch", "active_timeout_en",
              "active_timeout_thresh", "active_hdm_base", "active_hdm_size",
              "active_capacity", "occupancy"]

def gen_one(N_POOLS, AMT_W, COUNT_W, RESET_MAX, DEPTH, GEN_W):
    cp = ControlPlane(N_POOLS, AMT_W, COUNT_W, RESET_MAX, DEPTH, GEN_W,
                      EPOCH_W, OP_W, META_W, TS_W, HDM_W, CAP_W)
    m = cp.adm.trk
    amask = (1 << AMT_W) - 1
    half = 1 << (TS_W - 1)
    SLOT_W, TAG_W = m.SLOT_W, m.TAG_W
    granted = []
    ts = 0
    lines = []
    for cyc in range(N_CYCLES):
        ts = (ts + random.choice([0, 1, 1, 2, 5, THRESH + 3, half + 5])) & ((1 << TS_W) - 1)
        # --- config request (occasional) ---
        cfg_req_valid = 1 if random.random() < 0.06 else 0
        cfg_hdm_base = random.randint(0, (1 << HDM_W) - 1)
        cfg_hdm_size = 0 if random.random() < 0.1 else random.randint(1, (1 << HDM_W) - 1)
        cfg_capacity = 0 if random.random() < 0.1 else random.randint(1, (1 << CAP_W) - 1)
        cfg_timeout_en = 1 if random.random() < 0.7 else 0
        rr = random.random()
        cfg_timeout_thresh = (THRESH if rr < 0.7 else
                              (0 if rr < 0.8 else random.randint(1, (1 << TS_W) - 1)))
        cfg_cmax = []
        for p in range(N_POOLS):
            if random.random() < 0.15:
                cfg_cmax.append(random.randint(1 << COUNT_W, (1 << (COUNT_W + 1)) - 1))  # non-representable
            else:
                cfg_cmax.append(random.randint(0, (1 << COUNT_W) - 1))
        cfg_epoch = random.randint(0, (1 << EPOCH_W) - 1)
        cfg_rsp_ready = 0 if random.random() < 0.25 else 1
        # --- admission request ---
        req_valid = 1 if random.random() < 0.5 else 0
        req_op = random.randint(0, (1 << OP_W) - 1)
        req_meta = random.randint(0, (1 << META_W) - 1)
        cv = 0
        for p in range(N_POOLS):
            cv |= (random.choice([0, 0, 1, 1, 2, amask]) & amask) << (p * AMT_W)
        req_credit_vec = cv
        downstream_ready = 0 if random.random() < 0.3 else 1
        # --- response / reclaim ---
        resp_valid = 1 if random.random() < 0.4 else 0
        resp_tag = 0
        if resp_valid:
            r = random.random()
            if granted and r < 0.7:
                resp_tag = random.choice(granted)
            else:
                resp_tag = random.randint(0, (1 << TAG_W) - 1)
        reclaim_req_valid = 1 if random.random() < 0.12 else 0
        reclaim_tag = random.choice(granted) if (granted and random.random() < 0.6) \
            else random.randint(0, (1 << TAG_W) - 1)
        reclaim_rsp_ready = 0 if random.random() < 0.25 else 1

        # DRAIN accelerator: while draining, retire/reclaim live entries so the
        # commit is actually reached within the trace.
        if cp.state == S_DRAIN:
            live_nt = [x for x in range(DEPTH) if m.live[x] and not m.timed[x]]
            live_q = [x for x in range(DEPTH) if m.live[x] and m.timed[x]]
            if live_nt:
                sl = random.choice(live_nt)
                resp_valid = 1; resp_tag = (m.gen[sl] << SLOT_W) | sl
            elif live_q and cp.adm.trk.rr_valid == 0:
                sl = random.choice(live_q)
                reclaim_req_valid = 1; reclaim_tag = (m.gen[sl] << SLOT_W) | sl
                reclaim_rsp_ready = 1

        inp = dict(rst_n=1, current_ts=ts, cfg_req_valid=cfg_req_valid,
                   cfg_hdm_base=cfg_hdm_base, cfg_hdm_size=cfg_hdm_size, cfg_capacity=cfg_capacity,
                   cfg_timeout_en=cfg_timeout_en, cfg_timeout_thresh=cfg_timeout_thresh,
                   cfg_cmax=cfg_cmax, cfg_epoch=cfg_epoch, cfg_rsp_ready=cfg_rsp_ready,
                   req_valid=req_valid, req_op=req_op, req_meta=req_meta,
                   req_credit_vec=req_credit_vec, downstream_ready=downstream_ready,
                   resp_valid=resp_valid, resp_tag=resp_tag, reclaim_req_valid=reclaim_req_valid,
                   reclaim_tag=reclaim_tag, reclaim_rsp_ready=reclaim_rsp_ready)
        o = cp.outputs(inp)
        if o["req_accept"]:
            granted.append(o["issued_tag"])
            if len(granted) > 48:
                granted.pop(0)
        cmax_flat = 0
        for p in range(N_POOLS):
            cmax_flat |= (cfg_cmax[p] & ((1 << (COUNT_W + 1)) - 1)) << (p * (COUNT_W + 1))
        toks = [hx(ts), hx(cfg_req_valid), hx(cfg_hdm_base), hx(cfg_hdm_size), hx(cfg_capacity),
                hx(cfg_timeout_en), hx(cfg_timeout_thresh), hx(cmax_flat), hx(cfg_epoch),
                hx(cfg_rsp_ready), hx(req_valid), hx(req_op), hx(req_meta), hx(req_credit_vec),
                hx(downstream_ready), hx(resp_valid), hx(resp_tag), hx(reclaim_req_valid),
                hx(reclaim_tag), hx(reclaim_rsp_ready)]
        toks += [hx(o[f]) for f in OUT_SCALAR]
        toks += [hx(o["used"][p]) for p in range(N_POOLS)]
        toks += [hx(o["available"][p]) for p in range(N_POOLS)]
        lines.append(" ".join(toks))
        cp.step(inp)
    return lines

def main():
    tot = 0; commits = 0
    for (NP, AW, CW, RM, D, G) in CONFIGS:
        lines = gen_one(NP, AW, CW, RM, D, G)
        path = os.path.join(OUT, f"cp_{NP}p_{AW}a_{CW}c_{RM}m_{D}d_{G}g.vec")
        with open(path, "w") as f:
            f.write(f"{NP} {AW} {CW} {RM} {D} {G} {EPOCH_W} {OP_W} {META_W} {TS_W} {HDM_W} {CAP_W} {len(lines)}\n")
            f.write("\n".join(lines) + "\n")
        tot += len(lines)
    print(f"control-plane vectors: {tot} cycles across {len(CONFIGS)} configs")

if __name__ == "__main__":
    main()
