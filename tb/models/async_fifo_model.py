#!/usr/bin/env python3
# async_fifo_model.py — independent reference for rtl/core/async_fifo.sv.
# Event-driven two-clock model: each event is ONE clock edge in one domain
# (ev=0 -> write-domain edge, ev=1 -> read-domain edge). This lets a manually
# clocked SV testbench replay the exact same interleaving deterministically,
# so full/empty/rd_data can be differentially compared every edge.
import random, os

class AsyncFifo:
    def __init__(self, width, addr_w):
        self.W = width
        self.AW = addr_w
        self.PW = addr_w + 1
        self.DEPTH = 1 << addr_w
        self.PMOD = 1 << self.PW
        self.PMASK = self.PMOD - 1
        self.DMASK = (1 << width) - 1
        self.wbin = 0; self.rbin = 0
        self.wgray = 0; self.rgray = 0
        self.r2w = [0, 0]      # rgray synced into write domain (stage0, stage1)
        self.w2r = [0, 0]      # wgray synced into read domain (stage0, stage1)
        self.mem = [0] * self.DEPTH

    def b2g(self, b):
        return (b ^ (b >> 1)) & self.PMASK

    def _inv_top2(self, g):
        # flip the top two bits of a PW-bit gray value (full-detect condition)
        return (g ^ (0b11 << (self.PW - 2))) & self.PMASK

    def full(self):
        return 1 if self.wgray == self._inv_top2(self.r2w[1]) else 0

    def empty(self):
        return 1 if self.rgray == self.w2r[1] else 0

    def rd_data(self):
        return self.mem[self.rbin & (self.DEPTH - 1)] & self.DMASK

    def wr_edge(self, wr_en, wr_data):
        pre_full = self.full()
        rgray_pre = self.rgray
        if wr_en and not pre_full:
            self.mem[self.wbin & (self.DEPTH - 1)] = wr_data & self.DMASK
            self.wbin = (self.wbin + 1) & self.PMASK
            self.wgray = self.b2g(self.wbin)
        # r2w synchronizer samples pre-edge rgray
        self.r2w[1] = self.r2w[0]
        self.r2w[0] = rgray_pre

    def rd_edge(self, rd_en):
        pre_empty = self.empty()
        wgray_pre = self.wgray
        if rd_en and not pre_empty:
            self.rbin = (self.rbin + 1) & self.PMASK
            self.rgray = self.b2g(self.rbin)
        self.w2r[1] = self.w2r[0]
        self.w2r[0] = wgray_pre

    def step(self, ev, wr_en, wr_data, rd_en):
        if ev == 0:
            self.wr_edge(wr_en, wr_data)
        else:
            self.rd_edge(rd_en)
        return self.full(), self.empty(), self.rd_data()


def gen(width, addr_w, n, seed, path):
    random.seed(seed)
    fifo = AsyncFifo(width, addr_w)
    lines = []
    for _ in range(n):
        ev = random.randint(0, 1)
        wr_en = random.randint(0, 1) if ev == 0 else 0
        rd_en = random.randint(0, 1) if ev == 1 else 0
        wr_data = random.randint(0, (1 << width) - 1)
        full, empty, rdd = fifo.step(ev, wr_en, wr_data, rd_en)
        lines.append(f"{ev:x} {wr_en:x} {wr_data:x} {rd_en:x}  {full:x} {empty:x} {rdd:x}")
    with open(path, "w") as f:
        f.write(f"{width} {addr_w} {n}\n")
        f.write("\n".join(lines) + "\n")
    return path


if __name__ == "__main__":
    OUT = os.path.join(os.path.dirname(__file__), "..", "vectors")
    os.makedirs(OUT, exist_ok=True)
    CFGS = [(2, 2), (4, 2), (8, 3), (3, 4)]
    for (w, a) in CFGS:
        p = os.path.join(OUT, f"afifo_{w}w_{a}a.vec")
        gen(w, a, 8000, 0xAF1F0 + w * 16 + a, p)
        print(f"wrote {p}")
