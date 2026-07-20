#!/usr/bin/env python3
"""
scheduler_model.py — INDEPENDENT reference model for rw_scheduler (M5).
Bounded pending table; cross-address reordering with per-address program order
preserved by an age-matrix hazard interlock. Cycle semantics mirror the RTL:
outputs() are a pure function of pre-edge state + inputs; step() advances one edge.
All action targets (response-free, memory-issue, completion, accept) are on disjoint
slots, so the parallel apply matches the RTL's nonblocking writes.
"""


class Scheduler:
    def __init__(self, TAG_W=6, ADDR_W=8, DATA_W=8, DEPTH=4):
        self.TAG_W, self.ADDR_W, self.DATA_W, self.DEPTH = TAG_W, ADDR_W, DATA_W, DEPTH
        D = DEPTH
        self.vld = [0]*D; self.tag = [0]*D; self.wr = [0]*D; self.adr = [0]*D
        self.wdat = [0]*D; self.issd = [0]*D; self.done = [0]*D; self.rdat = [0]*D
        self.older = [[0]*D for _ in range(D)]     # older[i][j] == i older than j

    def _free_slot(self):
        fs, have = 0, 0
        for i in range(self.DEPTH):        # lowest-index free
            if not self.vld[i]:
                return i, 1
        return fs, have

    def _elig(self):
        D = self.DEPTH
        e = [0]*D
        for i in range(D):
            blk = 0
            for j in range(D):
                if self.vld[j] and self.older[j][i] and self.adr[j] == self.adr[i] and not self.done[j]:
                    blk = 1
            e[i] = 1 if (self.vld[i] and not self.issd[i] and not blk) else 0
        return e

    def _lowest(self, pred):
        for i in range(self.DEPTH):
            if pred(i):
                return i, 1
        return 0, 0

    def _decide(self, inp):
        fs, have = self._free_slot()
        iss_ready = 1 if (inp['rst_n'] and have) else 0
        accept = 1 if (inp['iss_valid'] and iss_ready) else 0
        elig = self._elig()
        mem_sel, mem_valid = self._lowest(lambda i: elig[i])
        rsp_sel, rsp_valid = self._lowest(lambda i: self.vld[i] and self.done[i])
        mc_hit = [1 if (inp['mc_valid'] and self.vld[i] and self.issd[i] and not self.done[i]
                        and self.tag[i] == inp['mc_tag']) else 0 for i in range(self.DEPTH)]
        return fs, iss_ready, accept, elig, mem_sel, mem_valid, rsp_sel, rsp_valid, mc_hit

    def outputs(self, inp):
        fs, iss_ready, accept, elig, mem_sel, mem_valid, rsp_sel, rsp_valid, mc_hit = self._decide(inp)
        occ = sum(self.vld)
        return dict(
            iss_ready=iss_ready,
            mem_valid=mem_valid,
            mem_tag=self.tag[mem_sel], mem_write=self.wr[mem_sel],
            mem_addr=self.adr[mem_sel], mem_wdata=self.wdat[mem_sel],
            rsp_valid=rsp_valid,
            rsp_tag=self.tag[rsp_sel], rsp_rdata=self.rdat[rsp_sel],
            occupancy=occ)

    def step(self, inp):
        if not inp['rst_n']:
            D = self.DEPTH
            self.vld = [0]*D; self.issd = [0]*D; self.done = [0]*D
            self.older = [[0]*D for _ in range(D)]
            self.tag = [0]*D; self.wr = [0]*D; self.adr = [0]*D; self.wdat = [0]*D; self.rdat = [0]*D
            return
        fs, iss_ready, accept, elig, mem_sel, mem_valid, rsp_sel, rsp_valid, mc_hit = self._decide(inp)
        do_mem = mem_valid and inp['mem_ready']
        do_rsp = rsp_valid and inp['rsp_ready']
        pre_vld = list(self.vld)               # age update reads pre-edge validity
        if do_rsp:
            self.vld[rsp_sel] = 0; self.issd[rsp_sel] = 0; self.done[rsp_sel] = 0
        if do_mem:
            self.issd[mem_sel] = 1
        for k in range(self.DEPTH):
            if mc_hit[k]:
                self.done[k] = 1; self.rdat[k] = inp['mc_rdata']
        if accept:
            self.vld[fs] = 1; self.tag[fs] = inp['iss_tag']; self.wr[fs] = inp['iss_write']
            self.adr[fs] = inp['iss_addr']; self.wdat[fs] = inp['iss_wdata']
            self.issd[fs] = 0; self.done[fs] = 0
            for k in range(self.DEPTH):
                self.older[fs][k] = 0
                if k != fs:
                    self.older[k][fs] = pre_vld[k]
        # light self-checks (safety invariants)
        assert sum(self.vld) <= self.DEPTH
        for i in range(self.DEPTH):
            assert not self.older[i][i]
            if self.vld[i] and self.done[i]:
                assert self.issd[i]
