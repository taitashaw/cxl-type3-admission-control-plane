#!/usr/bin/env python3
# gen_replay_vectors.py — M8 SOFTWARE_EMULATED replay. Translate the CXL Type-3
# window(s) CAPTURED from real QEMU 8.2.2 (capture.sh -> cap_*.json) into
# differential vectors for the EXISTING hdm_decoder + hdm_config testbenches, so
# the RTL's HDM-decode/config programming-model semantics are cross-checked
# against an actual CXL Type-3 emulation. Reuses the independent hdm_model.py
# reference (no second source of truth). Params fixed at N_WIN=4, HPA_W=40,
# DPA_W=32 (the production decode config; the captured HPAs ~0x490000000 fit).
import os, sys, json, glob

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "..", "tb", "models"))
from hdm_model import Window, Config, validate, decode  # noqa: E402

N_WIN, HPA_W, DPA_W, LINE = 4, 40, 32, 64
OUT = os.path.join(HERE, "..", "..", "tb", "vectors")
os.makedirs(OUT, exist_ok=True)   # tb/vectors is gitignored -> absent in a fresh clone

def hx(v): return format(int(v) & ((1 << 256) - 1), "x")

def mk_cfg(cap):
    # QEMU CXL window in slot 0 (base = captured HPA CFMW base, size = CFMW size,
    # dpa_base = 0, device capacity = captured DPA size); slots 1..3 disabled.
    base = cap["hpa_base"] & ((1 << HPA_W) - 1)
    win0 = Window(en=1, base=base, size=cap["hpa_size"], dpa_base=0)
    rest = [Window(en=0, base=0, size=0, dpa_base=0) for _ in range(N_WIN - 1)]
    return Config(windows=[win0] + rest, hpa_w=HPA_W, dpa_w=DPA_W,
                  dev_capacity=cap["dpa_size"])

def emit_dec(f, cfg, hpa):
    r = decode(cfg, hpa)
    toks = [hx(hpa), hx(cfg.dev_capacity)]
    for w in cfg.windows:
        toks += [hx(w.en), hx(w.base), hx(w.size), hx(w.dpa_base)]
    toks += [hx(r["accept"]), hx(r["miss"]), hx(r["overlap"]), hx(r["unaligned"]),
             hx(r["line_oob"]), hx(r["ovf"]), hx(r["oob"]), hx(r["dpa"])]
    f.write(" ".join(toks) + "\n")

def emit_cfg(f, cfg):
    ok, reason = validate(cfg)
    toks = [hx(cfg.dev_capacity)]
    for w in cfg.windows:
        toks += [hx(w.en), hx(w.base), hx(w.size), hx(w.dpa_base)]
    toks += [hx(1 if ok else 0), hx(reason)]
    f.write(" ".join(toks) + "\n")
    return ok, reason

def probes(cfg):
    w = cfg.windows[0]; b, s = w.base, w.size
    hs = [b, b + LINE, b + s - LINE, b + s, b + LINE // 2, (b - LINE) & ((1 << HPA_W) - 1), 0]
    # capacity boundary inside the window (last device-backed line, first past it)
    if cfg.dev_capacity <= s:
        hs += [b + cfg.dev_capacity - LINE, b + cfg.dev_capacity]
    return hs

def main():
    caps = sorted(glob.glob(os.path.join(HERE, "cap_*.json")))
    if not caps:
        print("BLOCKED: no cap_*.json captures present (run capture.sh first)")
        sys.exit(2)
    cfgs = [(os.path.basename(p), mk_cfg(json.load(open(p)))) for p in caps]

    # decoder vectors from every VALID captured window
    dec_rows = []
    for name, cfg in cfgs:
        if validate(cfg)[0]:
            for h in probes(cfg):
                dec_rows.append((cfg, h))
    dpath = os.path.join(OUT, "dec_qemu_replay.vec")
    with open(dpath, "w") as f:
        f.write(f"{N_WIN} {HPA_W} {DPA_W} {len(dec_rows)}\n")
        for cfg, h in dec_rows:
            emit_dec(f, cfg, h)

    # config-verdict vectors from EVERY captured window (accepts + the
    # window>device CFMW that our stricter validation rejects)
    cpath = os.path.join(OUT, "cfg_qemu_replay.vec")
    verdicts = []
    with open(cpath, "w") as f:
        f.write(f"{N_WIN} {HPA_W} {DPA_W} {len(cfgs)}\n")
        for name, cfg in cfgs:
            ok, reason = emit_cfg(f, cfg)
            verdicts.append((name, ok, reason))

    print(f"decoder replay vectors: {len(dec_rows)} ({dpath})")
    print(f"config  replay vectors: {len(cfgs)} ({cpath})")
    for name, ok, reason in verdicts:
        print(f"  {name}: config {'ACCEPT' if ok else f'REJECT(reason={reason})'}")

if __name__ == "__main__":
    main()
