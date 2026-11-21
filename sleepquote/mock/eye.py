# Draws the default sleep picture (an eye in a seed of life inside rings) as eye.svg, traced from
# the picture Lukas posted. Run: python3 eye.py OUT.svg
# KOReader's NanoSVG ignores clipPath (it fills the clip shape black), so the iris is clipped to the
# lids here in Python (Sutherland-Hodgman against the convex almond).
import math
import sys

C, R = 400, 136


def p(r, a):
    a = math.radians(a)
    return C + r * math.cos(a), C - r * math.sin(a)


def pts(poly):
    return " ".join(f"{x:.1f},{y:.1f}" for x, y in poly)


o = []
o.append(f'<circle cx="{C}" cy="{C}" r="386" stroke-width="1.8" stroke-dasharray="7 6" fill="none"/>')
o.append(f'<circle cx="{C}" cy="{C}" r="348" stroke-width="2.2" fill="none"/>')
o.append(f'<circle cx="{C}" cy="{C}" r="341" stroke-width="1.4" fill="none"/>')
o.append(f'<circle cx="{C}" cy="{C}" r="333" stroke-width="1.6" stroke-dasharray="1.5 4" fill="none"/>')
o.append(f'<circle cx="{C}" cy="{C}" r="{R}" stroke-width="2.2" fill="none"/>')
for k in range(6):
    x, y = p(R, 90 + 60 * k)
    o.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{R}" stroke-width="2.2" fill="none"/>')
dots = [p(R, 90 + 60 * k) for k in range(6)] + [p(R * math.sqrt(3), 60 * k) for k in range(6)] \
    + [p(2 * R, 90 + 60 * k) for k in range(6)]
for x, y in dots:
    o.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="11" fill="#000" stroke="none"/>')

# Eye: almond from two quadratic lids; white fill hides the geometry behind it.
L, Rt, cy, top, bot = 219, 590, 407, 267, 523


def quad(x0, y0, cx, cy_, x1, y1, n=48):
    return [((1 - t) ** 2 * x0 + 2 * (1 - t) * t * cx + t * t * x1,
             (1 - t) ** 2 * y0 + 2 * (1 - t) * t * cy_ + t * t * y1) for t in (i / n for i in range(n + 1))]


almond = quad(L, cy, 404, top, Rt, cy) + quad(Rt, cy, 404, bot, L, cy)[1:-1]
o.append(f'<polygon points="{pts(almond)}" fill="#fff" stroke="none"/>')


def inside(pt, a, b):
    # almond runs clockwise on screen (y down), so inside is to the right of each edge
    return (b[0] - a[0]) * (pt[1] - a[1]) - (b[1] - a[1]) * (pt[0] - a[0]) >= 0


def cross(p1, p2, a, b):
    x1, y1, x2, y2 = *p1, *p2
    x3, y3, x4, y4 = *a, *b
    d = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
    t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / d
    return x1 + t * (x2 - x1), y1 + t * (y2 - y1)


def clip(poly):
    out = poly
    for i in range(len(almond)):
        a, b = almond[i], almond[(i + 1) % len(almond)]
        src, out = out, []
        for j in range(len(src)):
            cur, prev = src[j], src[j - 1]
            if inside(cur, a, b):
                if not inside(prev, a, b):
                    out.append(cross(prev, cur, a, b))
                out.append(cur)
            elif inside(prev, a, b):
                out.append(cross(prev, cur, a, b))
        if not out:
            break
    return out


def disc(cx, cy_, r, n=96):
    return [(cx + r * math.cos(2 * math.pi * i / n), cy_ + r * math.sin(2 * math.pi * i / n)) for i in range(n)]


ix, iy = 400, 394
o.append(f'<polygon points="{pts(clip(disc(ix, iy, 66)))}" fill="#000" stroke="none"/>')
for rr in (60, 52, 44):
    ring = clip(disc(ix, iy, rr))
    if ring:
        o.append(f'<polygon points="{pts(ring)}" stroke="#fff" stroke-width="1.3" fill="none"/>')
for k in range(32):
    a = k * math.pi / 16
    seg = clip([(ix + 34 * math.cos(a), iy + 34 * math.sin(a)), (ix + 63 * math.cos(a), iy + 63 * math.sin(a))])
    if len(seg) >= 2:
        o.append(f'<polyline points="{pts(seg[:2])}" stroke="#fff" stroke-width="1" fill="none"/>')
o.append(f'<circle cx="{ix}" cy="{iy}" r="32" fill="#000" stroke="none"/>')
o.append(f'<circle cx="{ix + 25}" cy="{iy - 24}" r="13" fill="#fff" stroke="none"/>')

# Lids drawn last so they cover the clipped edges: heavy upper lid with a flick at each corner,
# a crease above, a thin lower lid with a second line under it, two dots by the inner corner.
o.append(f'<path d="M{L - 8} {cy - 1} Q404 {top - 4} {Rt + 8} {cy - 1}" stroke-width="10" fill="none"/>')
o.append(f'<path d="M{L + 40} {cy - 18} Q404 {top - 26} {Rt - 30} {cy - 22}" stroke-width="2.2" fill="none"/>')
o.append(f'<path d="M{L - 8} {cy - 1} Q{L - 24} {cy + 6} {L - 34} {cy + 4}" stroke-width="4" fill="none"/>')
o.append(f'<path d="M{Rt + 8} {cy - 1} Q{Rt + 26} {cy + 8} {Rt + 38} {cy + 6}" stroke-width="4" fill="none"/>')
o.append(f'<path d="M{L + 6} {cy + 4} Q404 {bot - 4} {Rt - 6} {cy + 4}" stroke-width="3.5" fill="none"/>')
o.append(f'<path d="M{L + 50} {cy + 22} Q404 {bot + 2} {Rt - 50} {cy + 22}" stroke-width="1.6" fill="none"/>')
for x, y in ((L + 12, cy - 14), (L + 16, cy - 2)):
    o.append(f'<circle cx="{x}" cy="{y}" r="3.2" fill="#000" stroke="none"/>')

svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 800" width="800" height="800">'
       '<rect width="800" height="800" fill="#fff"/><g stroke="#000" stroke-linecap="round">' + "".join(o) + "</g></svg>")
open(sys.argv[1], "w").write(svg)
