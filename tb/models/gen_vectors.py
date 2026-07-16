#!/usr/bin/env python3
"""
gen_vectors.py — generate differential test vectors from the INDEPENDENT
reference model (hdm_model.py) for the SV testbenches.

Outputs (under tb/vectors/):
  dec_<NWIN>w_<HPAW>x<DPAW>.vec   decoder+translator combinational vectors
  cfg_<NWIN>w_<HPAW>x<DPAW>.vec   config-validation / commit-verdict vectors

Decoder .vec format:
  line1: "N_WIN HPA_W DPA_W COUNT"
  each vector line (all hex):
    hpa cap  [en base size dpa]*N_WIN  accept miss overlap unaligned ovf oob dpa

Config .vec format:
  line1: "N_WIN HPA_W DPA_W COUNT"
  each line (all hex):
    cap [en base size dpa]*N_WIN  valid reason

Deterministic (fixed seed) -> reproducible. Emits counts to stdout.
"""
import os, random
from hdm_model import Window, Config, validate, decode

random.seed(0xC5100)
OUT = os.path.join(os.path.dirname(__file__), "..", "vectors")
os.makedirs(OUT, exist_ok=True)
LINE = 64

# (N_WIN, HPA_W, DPA_W) sweep — includes 1/2/4/8 windows and reduced+prod widths
SWEEP = [(1, 32, 24), (2, 40, 32), (4, 40, 32), (8, 44, 36)]
N_RAND_DEC = 4000
N_RAND_CFG = 2000

def aligned(x): return x - (x % LINE)

def rand_window(hpa_w, dpa_w, cap, force_valid):
    if random.random() < 0.25 and not force_valid:
        en = 0
        return Window(0, 0, 0, 0)
    hpa_max = 1 << hpa_w
    # base/size chosen to usually fit; occasionally break a rule if not force_valid
    size = aligned(random.randint(1, max(1, hpa_max // 8))) or LINE
    base = aligned(random.randint(0, max(0, hpa_max - size)))
    dcap = cap
    dpa_base = aligned(random.randint(0, max(0, dcap - size))) if dcap > size else 0
    w = Window(1, base, size, dpa_base)
    if not force_valid and random.random() < 0.35:
        kind = random.choice(["zsize", "balign", "salign", "dalign", "hovf", "dovf", "cap"])
        if kind == "zsize":  w.size = 0
        elif kind == "balign": w.base += LINE // 2
        elif kind == "salign": w.size += LINE // 2
        elif kind == "dalign": w.dpa_base += LINE // 2
        elif kind == "hovf":   w.base = hpa_max - LINE; w.size = 4 * LINE
        elif kind == "dovf":   w.dpa_base = (1 << dpa_w) - LINE; w.size = 4 * LINE
        elif kind == "cap":    w.dpa_base = max(0, cap - LINE); w.size = 4 * LINE
    return w

def maybe_overlap(cfg):
    # occasionally clone a window's range into another enabled slot to force overlap
    ens = [i for i, w in enumerate(cfg.windows) if w.en]
    if len(ens) >= 2 and random.random() < 0.3:
        a, b = random.sample(ens, 2)
        wa = cfg.windows[a]
        cfg.windows[b] = Window(1, wa.base, wa.size, cfg.windows[b].dpa_base)

def rand_config(n_win, hpa_w, dpa_w, force_valid):
    cap = aligned(random.randint(1 << (dpa_w - 2), (1 << dpa_w))) or (1 << (dpa_w - 1))
    cap = min(cap, 1 << dpa_w)
    wins = [rand_window(hpa_w, dpa_w, cap, force_valid) for _ in range(n_win)]
    cfg = Config(hpa_w, dpa_w, cap, wins)
    if not force_valid:
        maybe_overlap(cfg)
    return cfg

def hx(v): return format(int(v) & ((1 << 256) - 1), "x")

def emit_dec(f, cfg, hpa):
    r = decode(cfg, hpa)
    toks = [hx(hpa), hx(cfg.dev_capacity)]
    for w in cfg.windows:
        toks += [hx(w.en), hx(w.base), hx(w.size), hx(w.dpa_base)]
    toks += [hx(r["accept"]), hx(r["miss"]), hx(r["overlap"]), hx(r["unaligned"]),
             hx(r["ovf"]), hx(r["oob"]), hx(r["dpa"])]
    f.write(" ".join(toks) + "\n")

def directed_hpas(cfg):
    hs = []
    for w in cfg.windows:
        if w.en and w.size > 0:
            hs += [w.base, w.base + w.size - LINE, (w.base - LINE) & ((1 << cfg.hpa_w) - 1),
                   w.base + w.size, w.base + LINE // 2]  # incl. an unaligned probe
    hs.append(0)
    hs.append((1 << cfg.hpa_w) - LINE)
    return hs

def main():
    total_dec = total_cfg = 0
    accepts = rejects = overlaps = 0
    for (n, h, d) in SWEEP:
        # ---- decoder vectors (three buckets for balanced coverage) ----
        path = os.path.join(OUT, f"dec_{n}w_{h}x{d}.vec")
        rows = []
        mask = (1 << h) - 1
        # (a) accept-targeted: valid non-overlapping config, aligned in-window hpa
        for _ in range(int(N_RAND_DEC * 0.45)):
            cfg = rand_config(n, h, d, force_valid=True)
            ens = [w for w in cfg.windows if w.en and w.size > 0]
            if not ens:
                rows.append((cfg, 0)); continue
            w = random.choice(ens)
            noff = max(1, w.size // LINE)
            hpa = w.base + LINE * random.randint(0, noff - 1)   # aligned, in-range -> accept
            if random.random() < 0.15:                          # sometimes unaligned probe
                hpa = (hpa + LINE // 2) & mask
            rows.append((cfg, hpa & mask))
        # (b) adversarial: random (possibly invalid/overlapping) config + random hpa
        for _ in range(int(N_RAND_DEC * 0.35)):
            cfg = rand_config(n, h, d, force_valid=False)
            hpa = random.randint(0, mask)
            if random.random() < 0.4:
                ens = [w for w in cfg.windows if w.en and w.size > 0]
                if ens:
                    w = random.choice(ens)
                    hpa = (w.base + random.randint(-LINE, w.size + LINE)) & mask
            rows.append((cfg, hpa))
        # (c) boundary edge cases from clean valid configs
        for _ in range(int(N_RAND_DEC * 0.20 // 8) + 1):
            cfgv = rand_config(n, h, d, force_valid=True)
            for hpa in directed_hpas(cfgv):
                rows.append((cfgv, hpa & mask))
        with open(path, "w") as f:
            f.write(f"{n} {h} {d} {len(rows)}\n")
            for cfg, hpa in rows:
                emit_dec(f, cfg, hpa)
                r = decode(cfg, hpa)
                accepts += r["accept"]; overlaps += r["overlap"]
        total_dec += len(rows)

        # ---- config-validation vectors ----
        cpath = os.path.join(OUT, f"cfg_{n}w_{h}x{d}.vec")
        crows = []
        for _ in range(N_RAND_CFG):
            fv = random.random() < 0.5
            crows.append(rand_config(n, h, d, force_valid=fv))
        with open(cpath, "w") as f:
            f.write(f"{n} {h} {d} {len(crows)}\n")
            for cfg in crows:
                ok, reason = validate(cfg)
                if not ok: rejects += 1
                toks = [hx(cfg.dev_capacity)]
                for w in cfg.windows:
                    toks += [hx(w.en), hx(w.base), hx(w.size), hx(w.dpa_base)]
                toks += [hx(1 if ok else 0), hx(reason)]
                f.write(" ".join(toks) + "\n")
        total_cfg += len(crows)

    print(f"decoder vectors: {total_dec} (accepts={accepts}, overlaps={overlaps})")
    print(f"config  vectors: {total_cfg} (rejects={rejects})")

if __name__ == "__main__":
    main()
