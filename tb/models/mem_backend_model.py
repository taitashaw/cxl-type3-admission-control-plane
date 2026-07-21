#!/usr/bin/env python3
"""
mem_backend_model.py — INDEPENDENT reference model for mem_backend (M6). Behavioral
memory + completion FIFO. outputs() is pure over pre-edge state; step() advances one
edge. A read captures mem[addr] at accept; a write updates mem[addr]; each request
enqueues a completion {tag, rdata}; the head is presented and popped when valid.
"""
from collections import deque


class MemBackend:
    def __init__(self, TAG_W=6, ADDR_W=4, DATA_W=8, CQ_DEPTH=4):
        self.TAG_W, self.ADDR_W, self.DATA_W, self.CQ_DEPTH = TAG_W, ADDR_W, DATA_W, CQ_DEPTH
        self.mem = [0] * (1 << ADDR_W)
        self.cq = deque()                    # entries: (tag, data)

    def outputs(self, inp):
        req_ready = 1 if (inp['rst_n'] and len(self.cq) != self.CQ_DEPTH) else 0
        cmp_valid = 1 if len(self.cq) != 0 else 0
        htag, hdat = (self.cq[0] if self.cq else (0, 0))
        return dict(req_ready=req_ready, cmp_valid=cmp_valid, cmp_tag=htag, cmp_rdata=hdat)

    def step(self, inp):
        if not inp['rst_n']:
            self.mem = [0] * (1 << self.ADDR_W)
            self.cq = deque()
            return
        accept = inp['req_valid'] and (len(self.cq) != self.CQ_DEPTH)
        pop = 1 if (len(self.cq) != 0 and inp['cmp_ready']) else 0
        rd_val = self.mem[inp['req_addr']]          # pre-edge read value
        if pop:
            self.cq.popleft()
        if accept:
            if inp['req_write']:
                self.mem[inp['req_addr']] = inp['req_wdata']
                self.cq.append((inp['req_tag'], 0))
            else:
                self.cq.append((inp['req_tag'], rd_val))
        assert len(self.cq) <= self.CQ_DEPTH
