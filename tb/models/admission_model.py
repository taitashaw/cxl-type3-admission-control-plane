#!/usr/bin/env python3
"""
admission_model.py — INDEPENDENT reference model for admission_top (M4 Phase 2b).

Wraps the verified Tracker reference model with a credit ledger and a one-entry
issue buffer, and reproduces the atomic admission datapath:
  - ONE authoritative event req_accept = req_valid && req_ready, where req_ready
    depends only on pre-edge / config-stable state (enable, !tracker_full,
    consume legality, issue-buffer ready);
  - all allocation-side effects (tracker alloc, credit consume, issue enqueue)
    fire iff req_accept;
  - credits returned via the tracker's combinational commit sidebands, aggregated
    per pool (retire + reclaim) and applied to the ledger exactly once;
  - credit conservation used[p] == sum(live entries' stored credit[p]) held every
    cycle (self-checked in step()).

Cycle semantics mirror the RTL: outputs() are a pure function of pre-edge state +
current inputs; step() advances one clock edge.
"""
from tracker_model import Tracker


class Admission:
    def __init__(self, N_POOLS=2, AMT_W=3, COUNT_W=6, RESET_MAX=8,
                 DEPTH=4, GEN_W=4, EPOCH_W=8, OP_W=2, META_W=8, TS_W=8):
        self.N_POOLS, self.AMT_W, self.COUNT_W, self.RESET_MAX = N_POOLS, AMT_W, COUNT_W, RESET_MAX
        self.CREDIT_VEC_W = N_POOLS * AMT_W
        self.amask = (1 << AMT_W) - 1
        # credit ledger (authoritative used[]; max fixed at RESET_MAX this phase)
        self.used = [0] * N_POOLS
        self.cmax = [RESET_MAX] * N_POOLS
        # issue buffer (one entry)
        self.issue_full = 0
        self.issue_tag = 0
        # tracker with CREDIT_W = flat per-pool credit vector
        self.trk = Tracker(DEPTH, GEN_W, EPOCH_W, OP_W, META_W, TS_W, self.CREDIT_VEC_W)

    # ---- credit-vector helpers ----
    def _vec_pool(self, vec, p):
        return (vec >> (p * self.AMT_W)) & self.amask

    def _consume_ready(self, req_credit_vec):
        for p in range(self.N_POOLS):
            if self._vec_pool(req_credit_vec, p) > self.cmax[p] - self.used[p]:
                return 0
        return 1

    # ---- combinational admission signals from pre-edge state ----
    def _admit(self, inp):
        full = 1 if self.trk.full() else 0
        c_ready = self._consume_ready(inp['req_credit_vec'])
        i_ready = 0 if self.issue_full else 1
        req_ready = 1 if (inp['rst_n'] and inp['req_accept_enable'] and not full
                          and c_ready and i_ready) else 0
        req_accept = 1 if (inp['req_valid'] and req_ready) else 0
        return req_ready, req_accept, c_ready

    def _tracker_inp(self, inp, req_accept):
        return dict(current_ts=inp['current_ts'], timeout_enable=inp['timeout_enable'],
                    timeout_thresh=inp['timeout_thresh'],
                    alloc_req=req_accept, alloc_epoch=inp['active_epoch'], alloc_op=inp['req_op'],
                    alloc_meta=inp['req_meta'], alloc_credit_vec=inp['req_credit_vec'],
                    resp_valid=inp['resp_valid'], resp_tag=inp['resp_tag'],
                    reclaim_req_valid=inp['reclaim_req_valid'], reclaim_tag=inp['reclaim_tag'],
                    reclaim_rsp_ready=inp['reclaim_rsp_ready'])

    def _return_agg(self, to):
        """per-pool aggregate of retire + reclaim commit vectors (widened)."""
        agg = [0] * self.N_POOLS
        for p in range(self.N_POOLS):
            r = self._vec_pool(to['retire_commit_credit_vec'], p) if to['retire_commit_fire'] else 0
            k = self._vec_pool(to['reclaim_commit_credit_vec'], p) if to['reclaim_commit_fire'] else 0
            agg[p] = r + k
        ret_valid = 1 if (to['retire_commit_fire'] or to['reclaim_commit_fire']) else 0
        return agg, ret_valid

    def outputs(self, inp):
        req_ready, req_accept, _ = self._admit(inp)
        tinp = self._tracker_inp(inp, req_accept)
        to = self.trk.outputs(tinp)
        agg, ret_valid = self._return_agg(to)
        avail = [self.cmax[p] - self.used[p] for p in range(self.N_POOLS)]
        return dict(
            req_ready=req_ready, req_accept=req_accept,
            tracker_alloc_fire=to['alloc_gnt'], credit_consume_fire=req_accept,
            issue_enqueue=req_accept, issue_valid=self.issue_full,
            issued_tag=to['alloc_tag'], issue_tag=self.issue_tag,
            resp_retire=to['resp_retire'], resp_class=to['resp_class'],
            retired_epoch=to['retired_epoch'],
            reclaim_req_ready=to['reclaim_req_ready'], reclaim_rsp_valid=to['reclaim_rsp_valid'],
            reclaim_rsp_tag=to['reclaim_rsp_tag'], reclaim_rsp_class=to['reclaim_rsp_class'],
            credit_return_valid=ret_valid, credit_return_accepted=ret_valid,
            occupancy=to['occupancy'],
            used=list(self.used), available=avail)

    def step(self, inp):
        req_ready, req_accept, _ = self._admit(inp)
        tinp = self._tracker_inp(inp, req_accept)
        to = self.trk.outputs(tinp)
        agg, ret_valid = self._return_agg(to)
        # ledger update (consume on accept, aggregated return once)
        for p in range(self.N_POOLS):
            camt = self._vec_pool(inp['req_credit_vec'], p) if req_accept else 0
            ramt = agg[p] if ret_valid else 0
            self.used[p] = self.used[p] + camt - ramt
        # issue buffer
        if self.issue_full and inp['downstream_ready']:
            self.issue_full = 0
        if req_accept:
            self.issue_full = 1
            self.issue_tag = to['alloc_tag']
        # advance the tracker
        self.trk.step(tinp)
        # ---- conservation self-check (used[p] == live credit sum) ----
        for p in range(self.N_POOLS):
            s = sum(self._vec_pool(self.trk.credit_vec[i], p)
                    for i in range(self.trk.DEPTH) if self.trk.live[i])
            assert self.used[p] == s, \
                f"CONSERVATION VIOLATION pool {p}: used={self.used[p]} live_sum={s}"
            assert 0 <= self.used[p] <= self.cmax[p], \
                f"LEDGER BOUND VIOLATION pool {p}: used={self.used[p]} max={self.cmax[p]}"
