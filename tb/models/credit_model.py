#!/usr/bin/env python3
"""
credit_model.py — INDEPENDENT reference model for credit_manager.

Ledger semantics (see docs/credit_contract.md):
  authoritative state : used[p], configured_max[p]
  derived             : available[p] = configured_max[p] - used[p]
  invariant           : 0 <= used[p] <= configured_max[p]

  consume legal  <=> for EVERY pool: consume_amount[p] <= available[p]   (pre-cycle)
  return  legal  <=> for EVERY pool: return_amount[p]  <= used[p]        (pre-cycle)
  next_used[p] = used[p] + accepted_consume[p] - accepted_return[p]

All-or-nothing across pools. Functional state NEVER clamps/saturates; illegal
operations are rejected with state preserved + a sticky first-error snapshot.
Diagnostic counters saturate. Credits returned this cycle do NOT enable a consume
in the same cycle (legality uses registered pre-cycle state).
"""
ERR_NONE, ERR_RETURN_UNDERFLOW, ERR_CFG_REJECT = 0, 1, 2
CNT_MAX = (1 << 32) - 1
def sat1(c): return c if c >= CNT_MAX else c + 1

class Credit:
    def __init__(self, N_POOLS=2, COUNT_W=8, AMT_W=4, RESET_MAX=0):
        self.N = N_POOLS; self.COUNT_W = COUNT_W; self.AMT_W = AMT_W
        self.used = [0]*N_POOLS
        self.cmax = [RESET_MAX]*N_POOLS
        self.hwm  = [0]*N_POOLS
        self.sticky = 0; self.err_type = ERR_NONE; self.err_pool = 0; self.err_amt = 0
        self.c = dict(cons_ok=0, cons_blk=0, ret_ok=0, ret_ill=0, cfg_rej=0)

    # ---- combinational ----
    def available(self, p): return self.cmax[p] - self.used[p]
    def consume_legal(self, amt): return all(amt[p] <= self.available(p) for p in range(self.N))
    def return_legal(self, amt):  return all(amt[p] <= self.used[p]      for p in range(self.N))
    def all_unused(self):         return all(u == 0 for u in self.used)

    def outputs(self, inp):
        c_ok = self.consume_legal(inp['consume_amount'])
        r_ok = self.return_legal(inp['return_amount'])
        consume_ready   = 1 if c_ok else 0
        consume_fire    = 1 if (inp['consume_valid'] and c_ok) else 0
        return_accepted = 1 if (inp['return_valid']  and r_ok) else 0
        return dict(consume_ready=consume_ready, consume_fire=consume_fire,
                    return_accepted=return_accepted,
                    used=list(self.used), available=[self.available(p) for p in range(self.N)],
                    configured_max=list(self.cmax), hwm_used=list(self.hwm),
                    pool_full=[1 if self.used[p]==self.cmax[p] else 0 for p in range(self.N)],
                    pool_empty=[1 if self.used[p]==0 else 0 for p in range(self.N)],
                    sticky_err=self.sticky, first_err_type=self.err_type,
                    first_err_pool=self.err_pool, first_err_amount=self.err_amt,
                    consume_ok_count=self.c['cons_ok'], consume_blocked_count=self.c['cons_blk'],
                    return_ok_count=self.c['ret_ok'], return_illegal_count=self.c['ret_ill'],
                    cfg_reject_count=self.c['cfg_rej'])

    def step(self, inp):
        camt = inp['consume_amount']; ramt = inp['return_amount']
        c_ok = self.consume_legal(camt); r_ok = self.return_legal(ramt)
        cfire = inp['consume_valid'] and c_ok
        racc  = inp['return_valid'] and r_ok
        illegal_ret = inp['return_valid'] and not r_ok
        # commit gate excludes a same-cycle consume (credit-side of an allocation):
        # otherwise a consume checked against the OLD max could coexist with a new
        # smaller max, breaking used <= configured_max.
        gate_ok = inp['frozen_and_empty'] and self.all_unused() and not cfire
        cfg_apply  = inp['config_commit'] and gate_ok
        cfg_refuse = inp['config_commit'] and not gate_ok
        dclr = inp['diagnostic_clear']

        # ---- functional ledger (always; diagnostics never gate it) ----
        new_used = list(self.used)
        if cfire or racc:
            for p in range(self.N):
                new_used[p] = self.used[p] + (camt[p] if cfire else 0) - (ramt[p] if racc else 0)
        if cfg_apply:
            self.cmax = list(inp['committed_max'])

        # ---- diagnostics ----
        if dclr:
            self.sticky = 0; self.err_type = ERR_NONE; self.err_pool = 0; self.err_amt = 0
            self.c = dict(cons_ok=0, cons_blk=0, ret_ok=0, ret_ill=0, cfg_rej=0)
            self.hwm = list(new_used)
        else:
            if cfire: self.c['cons_ok'] = sat1(self.c['cons_ok'])
            if inp['consume_valid'] and not c_ok: self.c['cons_blk'] = sat1(self.c['cons_blk'])
            if racc:  self.c['ret_ok'] = sat1(self.c['ret_ok'])
            if illegal_ret:
                self.c['ret_ill'] = sat1(self.c['ret_ill'])
                if not self.sticky:
                    self.sticky = 1; self.err_type = ERR_RETURN_UNDERFLOW
                    bad = [p for p in range(self.N) if ramt[p] > self.used[p]]
                    self.err_pool = bad[0]; self.err_amt = ramt[bad[0]]
            if cfg_refuse:
                self.c['cfg_rej'] = sat1(self.c['cfg_rej'])
                if not self.sticky:
                    self.sticky = 1; self.err_type = ERR_CFG_REJECT; self.err_pool = 0; self.err_amt = 0
            if cfire or racc:
                for p in range(self.N):
                    if new_used[p] > self.hwm[p]: self.hwm[p] = new_used[p]
        self.used = new_used
