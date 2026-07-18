#!/usr/bin/env python3
"""
tracker_model.py — INDEPENDENT reference model for outstanding_tracker.

Cycle semantics mirror the RTL: combinational outputs are a function of the
CURRENT (pre-edge) state and the current inputs; registered outputs (occupancy,
watermark, counters) reflect the state produced by the previous clock edge.
`outputs(inp)` returns the sampled view for the cycle; `step(inp)` advances the
state by one clock edge using the same inputs.

Composite tag = (gen << SLOT_W) | slot.  Response classes:
  0 VALID  1 INVALID_SLOT  2 NON_LIVE  3 STALE_GEN
"""
RC_VALID, RC_INVALID_SLOT, RC_NON_LIVE, RC_STALE_GEN = 0, 1, 2, 3
# reclaim result classes
RCL_OK, RCL_INVALID_SLOT, RCL_NOT_LIVE, RCL_NOT_QUARANTINED, RCL_STALE_GEN, RCL_SUPERSEDED = 0, 1, 2, 3, 4, 5
CNT_MAX = (1 << 32) - 1

def sat1(c): return c if c >= CNT_MAX else c + 1
def satn(c, n): return CNT_MAX if c + n > CNT_MAX else c + n

class Tracker:
    def __init__(self, DEPTH=8, GEN_W=4, EPOCH_W=16, OP_W=2, META_W=32, TS_W=16, CREDIT_W=16):
        self.DEPTH, self.GEN_W, self.EPOCH_W = DEPTH, GEN_W, EPOCH_W
        self.OP_W, self.META_W, self.TS_W, self.CREDIT_W = OP_W, META_W, TS_W, CREDIT_W
        self.SLOT_W = 1 if DEPTH <= 1 else (DEPTH - 1).bit_length()
        self.TAG_W = GEN_W + self.SLOT_W
        self.gmask = (1 << GEN_W) - 1
        self.tsmask = (1 << TS_W) - 1
        self.half = 1 << (TS_W - 1)          # 2^(TS_W-1)
        self.live = [0]*DEPTH; self.gen = [0]*DEPTH; self.epoch = [0]*DEPTH
        self.op = [0]*DEPTH; self.meta = [0]*DEPTH; self.credit_vec = [0]*DEPTH; self.issue_ts = [0]*DEPTH
        self.timed = [0]*DEPTH
        self.occ = 0; self.hwm = 0
        self.c = dict(alloc=0, retire=0, full=0, timeout=0, reclaim=0, invalid=0, non_live=0, stale=0)
        self.err_sticky = 0; self.err_first = RC_VALID
        # registered reclaim-response state (handshake)
        self.rr_valid = 0; self.rr_class = RCL_OK; self.rr_meta = 0; self.rr_tag = 0

    def _reclaim_ready(self):
        return 0 if self.rr_valid else 1     # one in flight
    def _reclaim_accept(self, inp):
        return 1 if (inp['reclaim_req_valid'] and self._reclaim_ready()) else 0
    def _reclaim_class(self, inp, do_retire, r_slot):
        if not self._reclaim_accept(inp):
            return RCL_OK
        s = inp['reclaim_tag'] & ((1 << self.SLOT_W) - 1)
        g = (inp['reclaim_tag'] >> self.SLOT_W) & self.gmask
        if s >= self.DEPTH:              return RCL_INVALID_SLOT
        if not self.live[s]:             return RCL_NOT_LIVE
        if g != self.gen[s]:             return RCL_STALE_GEN
        if not self.timed[s]:            return RCL_NOT_QUARANTINED
        if do_retire and r_slot == s:    return RCL_SUPERSEDED   # response wins
        return RCL_OK
    def _reclaim_done(self, inp, do_retire, r_slot):
        return 1 if (self._reclaim_accept(inp) and self._reclaim_class(inp, do_retire, r_slot) == RCL_OK) else 0
    def _rc_slot(self, inp):
        return inp['reclaim_tag'] & ((1 << self.SLOT_W) - 1)

    # ---- combinational helpers ----
    def free_slot(self):
        for i in range(self.DEPTH):
            if not self.live[i]:
                return i, True
        return 0, False

    def full(self):
        return self.occ == self.DEPTH

    def classify(self, resp_valid, resp_tag):
        if not resp_valid:
            return RC_VALID, 0, 0
        slot = resp_tag & ((1 << self.SLOT_W) - 1)
        g = (resp_tag >> self.SLOT_W) & self.gmask
        if slot >= self.DEPTH:
            return RC_INVALID_SLOT, slot, g
        if not self.live[slot]:
            return RC_NON_LIVE, slot, g
        if g != self.gen[slot]:
            return RC_STALE_GEN, slot, g
        return RC_VALID, slot, g

    def outputs(self, inp):
        fs, have = self.free_slot()
        full = self.full()
        alloc_gnt = 1 if (inp['alloc_req'] and have and not full) else 0
        new_gen = (self.gen[fs] + 1) & self.gmask
        alloc_tag = (new_gen << self.SLOT_W) | fs
        rc, slot, g = self.classify(inp['resp_valid'], inp['resp_tag'])
        resp_retire = 1 if rc == RC_VALID and inp['resp_valid'] else 0
        slot_ok = inp['resp_valid'] and (slot < self.DEPTH)
        rr_ep = self.epoch[slot] if slot_ok else 0
        rr_op = self.op[slot] if slot_ok else 0
        rr_me = self.meta[slot] if slot_ok else 0
        # registered reclaim response is STATE (rr_*); ready is derived
        # combinational functional commit sidebands (pre-edge stored data)
        rc_slot = self._rc_slot(inp)
        r_success = self._reclaim_done(inp, resp_retire, slot)   # accept && class==RCL_OK
        rc_ok_idx = rc_slot < self.DEPTH
        timeout_any = 1 if any(self.live[i] and self.timed[i] for i in range(self.DEPTH)) else 0
        quarantined = sum(1 for i in range(self.DEPTH) if self.live[i] and self.timed[i])
        return dict(alloc_gnt=alloc_gnt, alloc_tag=alloc_tag, alloc_slot=fs, full=1 if full else 0,
                    resp_retire=resp_retire, resp_class=(rc if inp['resp_valid'] else RC_VALID),
                    retired_epoch=rr_ep, retired_op=rr_op, retired_meta=rr_me,
                    reclaim_req_ready=self._reclaim_ready(),
                    reclaim_rsp_valid=self.rr_valid, reclaim_rsp_class=self.rr_class,
                    reclaim_rsp_tag=self.rr_tag, reclaim_rsp_meta=self.rr_meta,
                    retire_commit_fire=resp_retire,
                    retire_commit_credit_vec=(self.credit_vec[slot] if resp_retire else 0),
                    retire_commit_epoch=(self.epoch[slot] if resp_retire else 0),
                    retire_commit_meta=(self.meta[slot] if resp_retire else 0),
                    reclaim_commit_fire=r_success,
                    reclaim_commit_credit_vec=(self.credit_vec[rc_slot] if (r_success and rc_ok_idx) else 0),
                    reclaim_commit_epoch=(self.epoch[rc_slot] if (r_success and rc_ok_idx) else 0),
                    reclaim_commit_meta=(self.meta[rc_slot] if (r_success and rc_ok_idx) else 0),
                    occupancy=self.occ, high_watermark=self.hwm,
                    quarantined_count=quarantined, timeout_any=timeout_any,
                    alloc_count=self.c['alloc'], retire_count=self.c['retire'], full_count=self.c['full'],
                    timeout_count=self.c['timeout'], reclaim_count=self.c['reclaim'],
                    invalid_slot_count=self.c['invalid'], non_live_count=self.c['non_live'],
                    stale_gen_count=self.c['stale'], err_sticky=self.err_sticky, err_first_class=self.err_first)

    def step(self, inp):
        fs, have = self.free_slot()
        full = self.full()
        do_alloc = 1 if (inp['alloc_req'] and have and not full) else 0
        rc, slot, g = self.classify(inp['resp_valid'], inp['resp_tag'])
        do_retire = 1 if (rc == RC_VALID and inp['resp_valid']) else 0
        # reclaim classification is COMBINATIONAL on PRE-EDGE state (mirrors the
        # RTL): capture accept/class/meta here, before the response side-effect
        # below can free the reclaim's target slot this same cycle.
        rc_slot = self._rc_slot(inp)
        reclaim_accept = self._reclaim_accept(inp)
        reclaim_cls = self._reclaim_class(inp, do_retire, slot)
        reclaim_meta_snap = self.meta[rc_slot] if rc_slot < self.DEPTH else 0
        do_reclaim = 1 if (reclaim_accept and reclaim_cls == RCL_OK) else 0
        ts = inp['current_ts']; th = inp['timeout_thresh']
        # committed timeout configuration (owned by hdm_config; used directly)
        active = 1 if (inp['timeout_enable'] and th != 0) else 0

        # timeout marking with event priority (exclude same-slot retire/reclaim)
        n_new = 0
        for i in range(self.DEPTH):
            if self.live[i] and not self.timed[i] and active:
                age = (ts - self.issue_ts[i]) & self.tsmask
                if age >= th and not (do_retire and slot == i) and not (do_reclaim and rc_slot == i):
                    self.timed[i] = 1; n_new += 1
        self.c['timeout'] = satn(self.c['timeout'], n_new)
        # response side effects
        if inp['resp_valid']:
            if rc == RC_VALID:
                self.live[slot] = 0; self.timed[slot] = 0; self.c['retire'] = sat1(self.c['retire'])
            elif rc == RC_INVALID_SLOT:
                self.c['invalid'] = sat1(self.c['invalid'])
                if not self.err_sticky: self.err_sticky = 1; self.err_first = RC_INVALID_SLOT
            elif rc == RC_NON_LIVE:
                self.c['non_live'] = sat1(self.c['non_live'])
                if not self.err_sticky: self.err_sticky = 1; self.err_first = RC_NON_LIVE
            elif rc == RC_STALE_GEN:
                self.c['stale'] = sat1(self.c['stale'])
                if not self.err_sticky: self.err_sticky = 1; self.err_first = RC_STALE_GEN
        # reclaim response registration + consumption (mutually exclusive with
        # accept, since accept requires not-pending). Response held until ready.
        # Uses the PRE-EDGE class/meta captured at the top of step().
        if self.rr_valid and inp['reclaim_rsp_ready']:
            self.rr_valid = 0
        if reclaim_accept:
            self.rr_valid = 1; self.rr_class = reclaim_cls; self.rr_tag = inp['reclaim_tag']
            # meta meaningful only on RCL_OK; force 0 otherwise (no stale metadata)
            self.rr_meta = reclaim_meta_snap if reclaim_cls == RCL_OK else 0
        # reclaim (recovery): free the quarantined slot
        if do_reclaim:
            self.live[rc_slot] = 0; self.timed[rc_slot] = 0
            self.c['reclaim'] = sat1(self.c['reclaim'])
        # allocation
        if do_alloc:
            self.live[fs] = 1
            self.gen[fs] = (self.gen[fs] + 1) & self.gmask
            self.epoch[fs] = inp['alloc_epoch']; self.op[fs] = inp['alloc_op']
            self.meta[fs] = inp['alloc_meta']; self.credit_vec[fs] = inp['alloc_credit_vec']
            self.issue_ts[fs] = ts; self.timed[fs] = 0
            self.c['alloc'] = sat1(self.c['alloc'])
        if inp['alloc_req'] and (full or not have):
            self.c['full'] = sat1(self.c['full'])
        # occupancy
        self.occ = self.occ + do_alloc - do_retire - do_reclaim
        if self.occ > self.hwm: self.hwm = self.occ
