#!/usr/bin/env python3
"""
gen_credit_vectors.py — differential vectors for credit_manager from the
independent model. One line per cycle: inputs then expected sampled outputs.
Deterministic. Exercises: consume-to-full, blocked consume, return-from-full,
simultaneous consume/return, ONE pool blocking a multi-pool consume, illegal
over-return, legal/rejected atomic reconfiguration, reset-adjacent activity,
zero-amount ops, and diagnostic clear.

File: credit_<N>p_<COUNT_W>c_<AMT_W>a.vec
  line1: N_POOLS COUNT_W AMT_W RESET_MAX COUNT
"""
import os, random
from credit_model import Credit

random.seed(0xC5ED17)
OUT = os.path.join(os.path.dirname(__file__), "..", "vectors")
os.makedirs(OUT, exist_ok=True)

# (N_POOLS, COUNT_W, AMT_W, RESET_MAX) -- maxima incl. 1,2,3,7 and pow2 boundaries
CONFIGS = [(1, 4, 2, 1), (2, 4, 2, 3), (3, 5, 3, 7), (2, 6, 3, 8), (1, 3, 2, 2)]
N_CYCLES = 4000

def hx(v): return format(int(v) & ((1 << 256) - 1), "x")

OUTF_SCALAR = ["consume_ready","consume_fire","return_accepted","sticky_err",
               "first_err_type","first_err_pool","first_err_amount",
               "consume_ok_count","consume_blocked_count","return_ok_count",
               "return_illegal_count","cfg_reject_count"]
OUTF_VEC    = ["used","available","configured_max","hwm_used","pool_full","pool_empty"]

def gen_one(N, COUNT_W, AMT_W, RESET_MAX, tally):
    m = Credit(N, COUNT_W, AMT_W, RESET_MAX)
    amax = (1 << AMT_W) - 1
    cmax_lim = (1 << COUNT_W) - 1
    lines = []
    for cyc in range(N_CYCLES):
        # amounts: biased small, sometimes zero, sometimes oversized (illegal)
        def amt():
            r = random.random()
            if r < 0.15: return 0
            if r < 0.85: return random.randint(0, min(2, amax))
            return random.randint(0, amax)
        consume_amount = [amt() for _ in range(N)]
        return_amount  = [amt() for _ in range(N)]
        # Bias returns toward legality (so the ledger actually drains).
        # MUST clamp to amax: the interface is AMT_W bits, so an amount > amax is
        # not representable -- emitting one would be a generator bug (the DUT
        # truncates while the model would not, causing a false divergence).
        if random.random() < 0.6:
            return_amount = [random.randint(0, min(m.used[p], amax)) if m.used[p] > 0 else 0
                             for p in range(N)]
        consume_valid = 1 if random.random() < 0.55 else 0
        return_valid  = 1 if random.random() < 0.45 else 0
        # configuration attempts: some legal (frozen+empty), some rejected
        config_commit = 1 if random.random() < 0.06 else 0
        frozen_and_empty = 1 if random.random() < 0.5 else 0
        committed_max = [random.choice([0,1,2,3,7,8,cmax_lim,random.randint(0,cmax_lim)]) for _ in range(N)]
        diagnostic_clear = 1 if random.random() < 0.02 else 0

        inp = dict(consume_valid=consume_valid, consume_amount=consume_amount,
                   return_valid=return_valid, return_amount=return_amount,
                   committed_max=committed_max, config_commit=config_commit,
                   frozen_and_empty=frozen_and_empty, diagnostic_clear=diagnostic_clear)
        # generator self-check: every amount must fit AMT_W
        assert all(0 <= x <= amax for x in consume_amount+return_amount), \
               f'generator emitted an amount > amax({amax}): {consume_amount} {return_amount}'
        o = m.outputs(inp)
        # TRUE event tally (the model's counters are clearable, so final values
        # are NOT coverage -- count the events as they are generated).
        if o['consume_fire']: tally['consume_fire'] += 1
        if consume_valid and not o['consume_ready']: tally['consume_blocked'] += 1
        if o['return_accepted']: tally['return_ok'] += 1
        if return_valid and not o['return_accepted']: tally['return_illegal'] += 1
        if config_commit and frozen_and_empty and all(u==0 for u in o['used']) and not o['consume_fire']: tally['cfg_apply'] += 1
        if config_commit and not (frozen_and_empty and all(u==0 for u in o['used']) and not o['consume_fire']): tally['cfg_refuse'] += 1
        if any(o['pool_full']): tally['pool_full'] += 1
        if consume_valid and not o['consume_ready'] and N > 1 and \
           sum(1 for q in range(N) if consume_amount[q] > o['available'][q]) == 1:
            tally['one_pool_blocks'] += 1
        if o['consume_fire'] and o['return_accepted']: tally['simultaneous'] += 1
        toks = [hx(consume_valid)] + [hx(x) for x in consume_amount] \
             + [hx(return_valid)]  + [hx(x) for x in return_amount] \
             + [hx(x) for x in committed_max] \
             + [hx(config_commit), hx(frozen_and_empty), hx(diagnostic_clear)]
        for f in OUTF_VEC:  toks += [hx(x) for x in o[f]]
        for f in OUTF_SCALAR: toks += [hx(o[f])]
        lines.append(" ".join(toks))
        m.step(inp)
    return m, lines

def main():
    tot = 0
    tally = dict(consume_fire=0, consume_blocked=0, return_ok=0, return_illegal=0,
                 cfg_apply=0, cfg_refuse=0, pool_full=0, one_pool_blocks=0, simultaneous=0)
    for (N, C, A, R) in CONFIGS:
        m, lines = gen_one(N, C, A, R, tally)
        path = os.path.join(OUT, f"credit_{N}p_{C}c_{A}a.vec")
        with open(path, "w") as f:
            f.write(f"{N} {C} {A} {R} {len(lines)}\n")
            f.write("\n".join(lines) + "\n")
        tot += len(lines)
    print(f"credit vectors: {tot} cycles across {len(CONFIGS)} configs")
    print(f"  event coverage: {tally}")

if __name__ == "__main__":
    main()
