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
ERR_NONE, ERR_RETURN_UNDERFLOW, ERR_CFG_BUSY, ERR_CFG_UNREP = 0, 1, 2, 3
def _sat1(c, mx): return c if c >= mx else c + 1

class Credit:
    def __init__(self, N_POOLS=2, COUNT_W=8, AMT_W=4, RESET_MAX=0, DIAG_W=32):
        self.N = N_POOLS; self.COUNT_W = COUNT_W; self.AMT_W = AMT_W
        self.DIAG_MAX = (1 << DIAG_W) - 1
        self.cmax_lim = (1 << COUNT_W) - 1      # largest representable max
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
    def representable(self, cmax): return all(c <= self.cmax_lim for c in cmax)

    def _s1(self, c): return _sat1(c, self.DIAG_MAX)
    def _decode(self, inp):
        camt = inp['consume_amount']; ramt = inp['return_amount']
        c_ok = self.consume_legal(camt); r_ok = self.return_legal(ramt)
        cmax = inp['committed_max']
        rep  = self.representable(cmax)
        cfg_fire   = inp['config_commit'] and inp['frozen_and_empty'] and self.all_unused() and rep
        cfg_refuse = inp['config_commit'] and not cfg_fire
        # config commit BLOCKS consume and return on that edge
        cfire = inp['consume_valid'] and c_ok and not cfg_fire
        racc  = inp['return_valid']  and r_ok and not cfg_fire
        illegal_ret = inp['return_valid'] and not r_ok and not cfg_fire
        cfg_reason = (ERR_CFG_UNREP if not rep else ERR_CFG_BUSY) if cfg_refuse else ERR_NONE
        return dict(c_ok=c_ok, r_ok=r_ok, rep=rep, cfg_fire=cfg_fire, cfg_refuse=cfg_refuse,
                    cfire=cfire, racc=racc, illegal_ret=illegal_ret, cfg_reason=cfg_reason)

    def outputs(self, inp):
        d = self._decode(inp)
        return dict(consume_ready=1 if d['c_ok'] else 0,
                    consume_fire=1 if d['cfire'] else 0,
                    return_accepted=1 if d['racc'] else 0,
                    cfg_commit_fire=1 if d['cfg_fire'] else 0,
                    cfg_reject=1 if d['cfg_refuse'] else 0,
                    cfg_reason=d['cfg_reason'],
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
        camt = inp['consume_amount']; ramt = inp['return_amount']; cmax = inp['committed_max']
        d = self._decode(inp); dclr = inp['diagnostic_clear']

        # ---- functional ledger ----
        new_used = list(self.used)
        if d['cfire'] or d['racc']:
            for p in range(self.N):
                new_used[p] = self.used[p] + (camt[p] if d['cfire'] else 0) - (ramt[p] if d['racc'] else 0)
        if d['cfg_fire']:
            self.cmax = [c & self.cmax_lim for c in cmax]   # representable -> low bits (no-op)

        # ---- diagnostics ----
        if dclr:
            self.sticky = 0; self.err_type = ERR_NONE; self.err_pool = 0; self.err_amt = 0
            self.c = dict(cons_ok=0, cons_blk=0, ret_ok=0, ret_ill=0, cfg_rej=0)
            self.hwm = list(new_used)
        else:
            if d['cfire']: self.c['cons_ok'] = self._s1(self.c['cons_ok'])
            if inp['consume_valid'] and not d['c_ok'] and not d['cfg_fire']: self.c['cons_blk'] = self._s1(self.c['cons_blk'])
            if d['racc']:  self.c['ret_ok'] = self._s1(self.c['ret_ok'])
            if d['illegal_ret']:
                self.c['ret_ill'] = self._s1(self.c['ret_ill'])
                if not self.sticky:
                    self.sticky = 1; self.err_type = ERR_RETURN_UNDERFLOW
                    bad = [p for p in range(self.N) if ramt[p] > self.used[p]]
                    self.err_pool = bad[0]; self.err_amt = ramt[bad[0]]
            if d['cfg_refuse']:
                self.c['cfg_rej'] = self._s1(self.c['cfg_rej'])
                if not self.sticky:
                    self.sticky = 1; self.err_type = d['cfg_reason']
                    if not d['rep']:
                        unrep = [p for p in range(self.N) if cmax[p] > self.cmax_lim]
                        self.err_pool = unrep[0]
                    else:
                        self.err_pool = 0
                    self.err_amt = 0
            # error PRIORITY: an illegal return outranks a cfg refusal for the
            # sticky snapshot -- both can occur, but cfg is blocked when cfg_fire
            # and illegal_ret is already excluded when cfg_fire, so at most one of
            # {illegal_ret, cfg_refuse} sets sticky in a way that matters; the
            # order above (return first) matches the RTL's err_now priority.
            if d['cfire'] or d['racc']:
                for p in range(self.N):
                    if new_used[p] > self.hwm[p]: self.hwm[p] = new_used[p]
        self.used = new_used
