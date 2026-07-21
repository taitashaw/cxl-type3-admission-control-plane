#!/usr/bin/env python3
"""
memsubsys_model.py — INDEPENDENT reference model for mem_subsys_top (M6). Wires the
Scheduler and MemBackend models and adds an END-TO-END read-after-write check: a
shadow memory is updated on each write's issue-accept (program order), and every
read response is verified to return the shadow value recorded when it was accepted.
"""
from scheduler_model import Scheduler
from mem_backend_model import MemBackend


class MemSubsys:
    def __init__(self, TAG_W=6, ADDR_W=2, DATA_W=8, DEPTH=4, CQ_DEPTH=4):
        self.ADDR_W, self.DATA_W = ADDR_W, DATA_W
        self.sch = Scheduler(TAG_W, ADDR_W, DATA_W, DEPTH)
        self.be = MemBackend(TAG_W, ADDR_W, DATA_W, CQ_DEPTH)
        self.shadow = [0] * (1 << ADDR_W)
        self.expected = {}                    # tag -> (is_write, expected_rdata)

    def _wire(self, inp):
        bo = self.be.outputs(dict(rst_n=inp['rst_n']))
        sched_inp = dict(rst_n=inp['rst_n'], iss_valid=inp['iss_valid'], iss_tag=inp['iss_tag'],
                         iss_write=inp['iss_write'], iss_addr=inp['iss_addr'], iss_wdata=inp['iss_wdata'],
                         mem_ready=bo['req_ready'], mc_valid=bo['cmp_valid'], mc_tag=bo['cmp_tag'],
                         mc_rdata=bo['cmp_rdata'], rsp_ready=inp['rsp_ready'])
        so = self.sch.outputs(sched_inp)
        be_inp = dict(rst_n=inp['rst_n'], req_valid=so['mem_valid'], req_tag=so['mem_tag'],
                      req_write=so['mem_write'], req_addr=so['mem_addr'], req_wdata=so['mem_wdata'],
                      cmp_ready=1)
        return bo, sched_inp, so, be_inp

    def outputs(self, inp):
        _, _, so, _ = self._wire(inp)
        return dict(iss_ready=so['iss_ready'], rsp_valid=so['rsp_valid'], rsp_tag=so['rsp_tag'],
                    rsp_rdata=so['rsp_rdata'], occupancy=so['occupancy'])

    def step(self, inp):
        _, sched_inp, so, be_inp = self._wire(inp)
        if inp['rst_n']:
            # issue-accept: record expected read value / update shadow (program order)
            if inp['iss_valid'] and so['iss_ready']:
                a = inp['iss_addr']
                if inp['iss_write']:
                    self.shadow[a] = inp['iss_wdata']
                    self.expected[inp['iss_tag']] = (1, 0)
                else:
                    self.expected[inp['iss_tag']] = (0, self.shadow[a])
            # response: verify a read returns the recorded value
            if so['rsp_valid'] and inp['rsp_ready']:
                t = so['rsp_tag']
                if t in self.expected:
                    is_w, exp = self.expected.pop(t)
                    if not is_w:
                        assert so['rsp_rdata'] == exp, \
                            f"READ-CORRECTNESS: tag {t} got {so['rsp_rdata']} exp {exp}"
        else:
            self.shadow = [0] * (1 << self.ADDR_W)
            self.expected = {}
        self.be.step(be_inp)
        self.sch.step(sched_inp)
