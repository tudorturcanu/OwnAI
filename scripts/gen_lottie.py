import json, os
# Generates the Lottie compositions in LocalAI/Animations. Run from the repo
# root: python3 scripts/gen_lottie.py

OUT = "LocalAI/Animations"

def static(v): return {"a": 0, "k": v}

def kf(frames, ease=(0.42, 0.58)):
    """frames: list of (t, value). Ease-in-out between each."""
    out = []
    for i, (t, v) in enumerate(frames):
        n = len(v) if isinstance(v, list) else 1
        k = {"t": t, "s": v if isinstance(v, list) else [v]}
        if i < len(frames) - 1:
            k["i"] = {"x": [ease[0]] * n, "y": [1] * n}
            k["o"] = {"x": [ease[1]] * n, "y": [0] * n}
        out.append(k)
    return {"a": 1, "k": out}

def transform(p=(0, 0), a=(0, 0), s=100, r=0, o=100):
    return {
        "o": o if isinstance(o, dict) else static(o),
        "r": r if isinstance(r, dict) else static(r),
        "p": p if isinstance(p, dict) else static([p[0], p[1], 0]),
        "a": static([a[0], a[1], 0]),
        "s": s if isinstance(s, dict) else static([s, s, 100]),
    }

def group_tr(p=(0, 0), s=100, r=0, o=100):
    return {"ty": "tr", "p": static(list(p)), "a": static([0, 0]),
            "s": s if isinstance(s, dict) else static([s, s]),
            "r": r if isinstance(r, dict) else static(r),
            "o": o if isinstance(o, dict) else static(o),
            "sk": static(0), "sa": static(0), "nm": "Transform"}

def layer(ind, name, shapes, ks, ip=0, op=180, parent=None):
    l = {"ddd": 0, "ind": ind, "ty": 4, "nm": name, "sr": 1, "ks": ks,
         "ao": 0, "shapes": shapes, "ip": ip, "op": op, "st": 0, "bm": 0}
    if parent is not None:
        l["parent"] = parent
    return l

def fill(rgb, name="Fill", o=100):
    return {"ty": "fl", "c": static(list(rgb) + [1]), "o": static(o), "r": 1, "bm": 0, "nm": name}

def gradient_fill(c1, c2, start, end, name="Gradient Fill"):
    return {"ty": "gf", "o": static(100), "r": 1, "bm": 0,
            "g": {"p": 2, "k": static([0, *c1, 1, *c2])},
            "s": static(list(start)), "e": static(list(end)), "t": 1, "nm": name}

def stroke(rgb, w, name="Stroke"):
    return {"ty": "st", "c": static(list(rgb) + [1]), "o": static(100),
            "w": static(w), "lc": 2, "lj": 2, "bm": 0, "nm": name}

def star(points, outer, inner, roundness=0, name="Star"):
    return {"ty": "sr", "sy": 1, "d": 1, "pt": static(points), "p": static([0, 0]),
            "r": static(0), "ir": static(inner), "is": static(roundness),
            "or": static(outer), "os": static(roundness), "ix": 1, "nm": name}

def ellipse(w, h, p=(0, 0), name="Ellipse"):
    return {"ty": "el", "d": 1, "s": static([w, h]), "p": static(list(p)), "nm": name}

def rect(size, r=0, name="Rect"):
    return {"ty": "rc", "d": 1, "s": size if isinstance(size, dict) else static(list(size)),
            "p": static([0, 0]), "r": static(r), "nm": name}

def group(items, name):
    return {"ty": "gr", "it": items, "nm": name, "bm": 0, "hd": False}

def comp(name, w, h, op, layers, fr=60):
    return {"v": "5.9.0", "fr": fr, "ip": 0, "op": op, "w": w, "h": h, "nm": name,
            "ddd": 0, "assets": [], "layers": layers}


# -------------------------------------------------------------- success check
# 100x100, 0.75 s. Circle pops in with a slight overshoot, then the tick draws.
OP = 45
circle = layer(2, "Circle", [group([
    ellipse(72, 72, name="Circle Path"),
    fill((0.2, 0.78, 0.35), name="Circle Fill"),
    group_tr(),
], "Circle")], transform(
    p=(50, 50),
    s=kf([(0, [0, 0, 100]), (16, [112, 112, 100]), (26, [100, 100, 100])], ease=(0.2, 0.4)),
    o=kf([(0, 0), (8, 100)]),
), op=OP)

check_path = {"ty": "sh", "d": 1, "nm": "Check Path", "ks": static({
    "c": False,
    "v": [[-15, 1], [-5, 11], [16, -11]],
    "i": [[0, 0], [0, 0], [0, 0]],
    "o": [[0, 0], [0, 0], [0, 0]],
})}
trim = {"ty": "tm", "s": static(0), "o": static(0), "m": 1, "nm": "Trim",
        "e": kf([(12, 0), (34, 100)], ease=(0.2, 0.6))}
check = layer(1, "Check", [group([
    check_path,
    trim,
    stroke((1, 1, 1), 7, name="Check Stroke"),
    group_tr(),
], "Check")], transform(p=(50, 50)), op=OP)

json.dump(comp("Success Check", 100, 100, OP, [check, circle]), open(f"{OUT}/success-check.json", "w"), separators=(",", ":"))

# ------------------------------------------------------------- voice waveform
# 48x32, 1.2 s loop. Five rounded bars pulse on staggered cycles.
OP = 72
bars = []
heights = [(8, 20), (10, 28), (8, 24), (10, 30), (8, 18)]
for i, (lo, hi) in enumerate(heights):
    off = (i * 11) % OP
    frames = [(0, [5, lo]), (18, [5, hi]), (36, [5, lo]), (54, [5, hi]), (OP, [5, lo])]
    # Stagger by rotating the keyframe times.
    shifted = []
    for t, v in frames:
        shifted.append(((t + off) % (OP + 1), v))
    shifted.sort()
    # Ensure a keyframe at 0 and OP for a clean loop.
    if shifted[0][0] != 0:
        shifted.insert(0, (0, shifted[-1][1]))
    if shifted[-1][0] != OP:
        shifted.append((OP, shifted[0][1]))
    bars.append(group([
        rect(kf(shifted), r=2.5, name="Bar Path"),
        fill((0.0, 0.48, 1.0), name="Bar Fill"),
        group_tr(p=(8 + i * 8, 16)),
    ], f"Bar {i+1}"))
wave = layer(1, "Bars", bars, transform(p=(0, 0)), op=OP)
json.dump(comp("Voice Wave", 48, 32, OP, [wave]), open(f"{OUT}/voice-wave.json", "w"), separators=(",", ":"))

for f in os.listdir(OUT):
    print(f, os.path.getsize(f"{OUT}/{f}"), "bytes")
