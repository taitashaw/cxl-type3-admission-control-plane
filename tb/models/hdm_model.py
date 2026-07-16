#!/usr/bin/env python3
"""
hdm_model.py — INDEPENDENT reference model for the HDM config/decode/translate
spec. Written in plain integer arithmetic (not mirroring the RTL's bit-slice
tricks) so it is a genuine second implementation for differential testing.

Spec it encodes (see docs/interface_contract.md):

Config validation (per ENABLED window), all must hold or the commit is rejected:
  * size > 0                              (no zero-size window)
  * base  % 64 == 0                       (64B-aligned base)
  * size  % 64 == 0                       (64B-aligned size)
  * dpa_base % 64 == 0                    (64B-aligned device base)
  * base + size <= 2**HPA_W               (no HPA range-end overflow)
  * dpa_base + size <= 2**DPA_W           (no DPA range-end overflow)
  * dpa_base + size <= dev_capacity       (window fits inside the device)
  * no two enabled windows overlap in HPA (pairwise)

Decode of one HPA against an ACTIVE config (config may be arbitrary here so the
combinational decoder can be exercised fail-closed with overlapping windows):
  matches        = enabled windows whose [base, base+size) contains hpa
  miss           = (len(matches) == 0)
  overlap_reject = (len(matches) >= 2)          # fail closed
  single         = (len(matches) == 1)
  unaligned      = (hpa % 64 != 0)
  on single match:
     offset          = hpa - base            (>= 0 by construction)
     dpa             = dpa_base + offset
     xlate_overflow  = dpa >= 2**DPA_W        (DPA-space wrap)
     dpa_oob         = dpa >= dev_capacity    (past installed device)
     accept          = single & ~unaligned & ~xlate_overflow & ~dpa_oob
  otherwise dpa=0, no xlate errors, accept=0
"""
from dataclasses import dataclass
from typing import List, Tuple

LINE = 64  # bytes

@dataclass
class Window:
    en: int
    base: int
    size: int
    dpa_base: int

@dataclass
class Config:
    hpa_w: int
    dpa_w: int
    dev_capacity: int
    windows: List[Window]

# ---- config validation --------------------------------------------------
# reason codes (kept in sync with rtl/csr/csr_pkg-style encoding in the TB)
CFG_OK          = 0
CFG_ZERO_SIZE   = 1
CFG_BASE_ALIGN  = 2
CFG_SIZE_ALIGN  = 3
CFG_DPA_ALIGN   = 4
CFG_HPA_OVF     = 5
CFG_DPA_OVF     = 6
CFG_CAP_EXCEED  = 7
CFG_OVERLAP     = 8

def validate(cfg: Config) -> Tuple[bool, int]:
    hpa_max = 1 << cfg.hpa_w
    dpa_max = 1 << cfg.dpa_w
    en = [w for w in cfg.windows if w.en]
    for w in en:
        if w.size == 0:                          return (False, CFG_ZERO_SIZE)
        if w.base % LINE != 0:                   return (False, CFG_BASE_ALIGN)
        if w.size % LINE != 0:                   return (False, CFG_SIZE_ALIGN)
        if w.dpa_base % LINE != 0:               return (False, CFG_DPA_ALIGN)
        if w.base + w.size > hpa_max:            return (False, CFG_HPA_OVF)
        if w.dpa_base + w.size > dpa_max:        return (False, CFG_DPA_OVF)
        if w.dpa_base + w.size > cfg.dev_capacity: return (False, CFG_CAP_EXCEED)
    # pairwise overlap among enabled windows
    for i in range(len(en)):
        for j in range(i + 1, len(en)):
            a, b = en[i], en[j]
            if a.base < b.base + b.size and b.base < a.base + a.size:
                return (False, CFG_OVERLAP)
    return (True, CFG_OK)

# ---- decode + translate -------------------------------------------------
def decode(cfg: Config, hpa: int) -> dict:
    matches = [k for k, w in enumerate(cfg.windows)
               if w.en and w.base <= hpa < w.base + w.size]
    n = len(matches)
    unaligned = 1 if (hpa % LINE != 0) else 0
    out = dict(miss=1 if n == 0 else 0,
               overlap=1 if n >= 2 else 0,
               single=1 if n == 1 else 0,
               unaligned=unaligned,
               win_id=matches[0] if n >= 1 else 0,
               ovf=0, oob=0, dpa=0, accept=0)
    if n == 1:
        w = cfg.windows[matches[0]]
        offset = hpa - w.base
        dpa = w.dpa_base + offset
        out["ovf"] = 1 if dpa >= (1 << cfg.dpa_w) else 0
        out["oob"] = 1 if dpa >= cfg.dev_capacity else 0
        out["dpa"] = dpa & ((1 << cfg.dpa_w) - 1)
        out["accept"] = 1 if (not unaligned and not out["ovf"] and not out["oob"]) else 0
    return out
