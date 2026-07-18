#!/usr/bin/env python3
"""
config_model.py — INDEPENDENT reference model for control_plane_top (M4 Phase 2c).
Wraps the Admission datapath model with the config_ctrl FSM: decoupled cfg
request/response, one immutable pending snapshot, validation, freeze, drain to full
quiescence, and ONE shared global commit on which every active field updates.
Cycle semantics mirror the RTL (pre-edge outputs; step advances one edge).
"""
from admission_model import Admission

RSP_OK, RSP_INVALID = 0, 1
RSN_OK, RSN_TIMEOUT, RSN_CMAX, RSN_HDM = 0, 1, 2, 3
S_IDLE, S_DRAIN, S_RSP_OK, S_RSP_INV = 0, 1, 2, 3


class ControlPlane:
    def __init__(self, N_POOLS, AMT_W, COUNT_W, RESET_MAX, DEPTH, GEN_W,
                 EPOCH_W, OP_W, META_W, TS_W, HDM_W, CAP_W):
        self.N_POOLS, self.COUNT_W = N_POOLS, COUNT_W
        self.TS_W, self.TS_HALF = TS_W, 1 << (TS_W - 1)
        self.adm = Admission(N_POOLS, AMT_W, COUNT_W, RESET_MAX, DEPTH, GEN_W,
                             EPOCH_W, OP_W, META_W, TS_W)
        self.state = S_IDLE
        self.p_base = self.p_size = self.p_cap = 0
        self.p_to_en = 0; self.p_to_thr = 0; self.p_cmax = [0] * N_POOLS; self.p_epoch = 0
        self.rsp_reason = RSN_OK
        self.active_to_en = 0; self.active_to_thr = 0; self.active_epoch = 0
        self.active_base = 0; self.active_size = 0; self.active_cap = 0

    def _req_valid_cfg(self, inp):
        to_ok = (not inp['cfg_timeout_en']) or \
                (inp['cfg_timeout_thresh'] != 0 and inp['cfg_timeout_thresh'] < self.TS_HALF)
        cmax_ok = all(v < (1 << self.COUNT_W) for v in inp['cfg_cmax'])
        hdm_ok = (inp['cfg_hdm_size'] != 0) and (inp['cfg_capacity'] != 0)
        valid = to_ok and cmax_ok and hdm_ok
        reason = RSN_TIMEOUT if not to_ok else (RSN_CMAX if not cmax_ok else
                 (RSN_HDM if not hdm_ok else RSN_OK))
        return valid, reason

    def _drive(self, inp):
        rst_n = inp['rst_n']
        cfg_req_ready = 1 if (rst_n and self.state == S_IDLE) else 0
        rae = 1 if (rst_n and self.state == S_IDLE) else 0
        base = dict(rst_n=rst_n, current_ts=inp['current_ts'],
                    timeout_enable=self.active_to_en, timeout_thresh=self.active_to_thr,
                    active_epoch=self.active_epoch, req_valid=inp['req_valid'],
                    req_accept_enable=rae, req_op=inp['req_op'], req_meta=inp['req_meta'],
                    req_credit_vec=inp['req_credit_vec'], downstream_ready=inp['downstream_ready'],
                    resp_valid=inp['resp_valid'], resp_tag=inp['resp_tag'],
                    reclaim_req_valid=inp['reclaim_req_valid'], reclaim_tag=inp['reclaim_tag'],
                    reclaim_rsp_ready=inp['reclaim_rsp_ready'],
                    cfg_config_commit=0, cfg_frozen_empty=0, cfg_committed_max=list(self.p_cmax))
        ao = self.adm.outputs(base)
        used_zero = all(u == 0 for u in ao['used'])
        quiescent = (ao['occupancy'] == 0 and ao['quarantined_count'] == 0 and used_zero
                     and not ao['issue_valid'] and not ao['req_accept']
                     and not ao['retire_commit_fire'] and not ao['reclaim_commit_fire'])
        gcommit = 1 if (rst_n and self.state == S_DRAIN and quiescent) else 0
        real = dict(base); real['cfg_config_commit'] = gcommit; real['cfg_frozen_empty'] = gcommit
        return cfg_req_ready, gcommit, quiescent, real

    def outputs(self, inp):
        cfg_req_ready, gcommit, quiescent, real = self._drive(inp)
        ao = self.adm.outputs(real)
        cfg_rsp_valid = 1 if self.state in (S_RSP_OK, S_RSP_INV) else 0
        cfg_rsp_code = RSP_INVALID if self.state == S_RSP_INV else RSP_OK
        return dict(
            cfg_req_ready=cfg_req_ready, cfg_rsp_valid=cfg_rsp_valid, cfg_rsp_code=cfg_rsp_code,
            cfg_rsp_reason=self.rsp_reason,
            req_ready=ao['req_ready'], req_accept=ao['req_accept'], issued_tag=ao['issued_tag'],
            issue_valid=ao['issue_valid'], issue_tag=ao['issue_tag'],
            resp_retire=ao['resp_retire'], resp_class=ao['resp_class'], retired_epoch=ao['retired_epoch'],
            reclaim_req_ready=ao['reclaim_req_ready'], reclaim_rsp_valid=ao['reclaim_rsp_valid'],
            reclaim_rsp_tag=ao['reclaim_rsp_tag'], reclaim_rsp_class=ao['reclaim_rsp_class'],
            global_cfg_commit_fire=gcommit,
            active_epoch=self.active_epoch, active_timeout_en=self.active_to_en,
            active_timeout_thresh=self.active_to_thr, active_hdm_base=self.active_base,
            active_hdm_size=self.active_size, active_capacity=self.active_cap,
            used=ao['used'], available=ao['available'], occupancy=ao['occupancy'])

    def step(self, inp):
        cfg_req_ready, gcommit, quiescent, real = self._drive(inp)
        self.adm.step(real)          # advance datapath (uses pre-edge active config)
        rst_n = inp['rst_n']
        if not rst_n:
            self.state = S_IDLE
            self.rsp_reason = RSN_OK
            self.active_to_en = 0; self.active_to_thr = 0; self.active_epoch = 0
            self.active_base = 0; self.active_size = 0; self.active_cap = 0
            return
        if self.state == S_IDLE:
            if inp['cfg_req_valid'] and cfg_req_ready:
                self.p_base = inp['cfg_hdm_base']; self.p_size = inp['cfg_hdm_size']
                self.p_cap = inp['cfg_capacity']; self.p_to_en = inp['cfg_timeout_en']
                self.p_to_thr = inp['cfg_timeout_thresh']; self.p_cmax = list(inp['cfg_cmax'])
                self.p_epoch = inp['cfg_epoch']
                valid, reason = self._req_valid_cfg(inp)
                self.rsp_reason = reason
                self.state = S_DRAIN if valid else S_RSP_INV
        elif self.state == S_DRAIN:
            if quiescent:
                self.active_base = self.p_base; self.active_size = self.p_size
                self.active_cap = self.p_cap; self.active_to_en = self.p_to_en
                self.active_to_thr = self.p_to_thr; self.active_epoch = self.p_epoch
                self.state = S_RSP_OK
        elif self.state in (S_RSP_OK, S_RSP_INV):
            if inp['cfg_rsp_ready']:
                self.state = S_IDLE
