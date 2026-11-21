# Draws the default sleep picture (eye in a seed of life with rays) as eye.svg. Run: python3 eye.py OUT.svg
import math
import sys

C, R = 400, 85


def p(r, a):
    a = math.radians(a)
    return C + r * math.cos(a), C - r * math.sin(a)


o = []
for k in range(12):
    r0, r1 = (180, 390) if k % 3 == 0 else (200, 385)
    (x0, y0), (x1, y1) = p(r0, k * 30), p(r1, k * 30)
    o.append(f'<line x1="{x0:.1f}" y1="{y0:.1f}" x2="{x1:.1f}" y2="{y1:.1f}" stroke-width="2.4"/>')
o.append(f'<circle cx="{C}" cy="{C}" r="243" stroke-width="1.6" stroke-dasharray="4 5" fill="none"/>')
o.append(f'<circle cx="{C}" cy="{C}" r="222" stroke-width="1.4" fill="none"/>')
o.append(f'<circle cx="{C}" cy="{C}" r="215" stroke-width="2.6" fill="none"/>')
o.append(f'<circle cx="{C}" cy="{C}" r="{R}" stroke-width="2" fill="none"/>')
for k in range(6):
    x, y = p(R, 90 + 60 * k)
    o.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{R}" stroke-width="2" fill="none"/>')
dots = [p(R, 90 + 60 * k) for k in range(6)] + [p(R * math.sqrt(3), 60 * k) for k in range(6)] \
    + [p(2 * R, 90 + 60 * k) for k in range(6)]
for x, y in dots:
    o.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="7.5" fill="#000" stroke="none"/>')

# Eye: a white almond hides the geometry behind it. The iris fits inside the lids with no clipPath:
# KOReader's NanoSVG ignores clipPath and fills its shape black.
L, Rt, cy = 268, 532, 404
almond = f"M{L} {cy} Q400 290 {Rt} {cy} Q400 500 {L} {cy} Z"
o.append(f'<path d="{almond}" fill="#fff" stroke="none"/>')
o.append(f'<path d="M{L - 10} {cy - 2} Q400 286 {Rt + 10} {cy - 2}" stroke-width="9" fill="none"/>')
o.append(f'<path d="M{L + 22} {cy - 12} Q400 312 {Rt - 22} {cy - 12}" stroke-width="2" fill="none"/>')
o.append(f'<path d="M{L - 10} {cy - 2} Q{L - 30} {cy + 4} {L - 40} {cy + 2}" stroke-width="4" fill="none"/>')
o.append(f'<path d="M{Rt + 10} {cy - 2} Q{Rt + 30} {cy + 4} {Rt + 40} {cy + 2}" stroke-width="4" fill="none"/>')
o.append(f'<path d="M{L + 8} {cy + 6} Q400 498 {Rt - 8} {cy + 6}" stroke-width="3.5" fill="none"/>')
o.append(f'<path d="M{L + 44} {cy + 14} Q400 478 {Rt - 44} {cy + 14}" stroke-width="1.4" fill="none"/>')
ic = (400, 400)
g = [f'<circle cx="{ic[0]}" cy="{ic[1]}" r="48" fill="#000" stroke="none"/>']
for rr in (43, 37, 31):
    g.append(f'<circle cx="{ic[0]}" cy="{ic[1]}" r="{rr}" stroke="#fff" stroke-width="1.2" fill="none"/>')
for k in range(28):
    a = k * math.pi / 14
    g.append(f'<line x1="{ic[0] + 22 * math.cos(a):.1f}" y1="{ic[1] + 22 * math.sin(a):.1f}" '
             f'x2="{ic[0] + 45 * math.cos(a):.1f}" y2="{ic[1] + 45 * math.sin(a):.1f}" stroke="#fff" stroke-width="0.9"/>')
g.append(f'<circle cx="{ic[0]}" cy="{ic[1]}" r="19" fill="#000" stroke="none"/>')
g.append(f'<circle cx="{ic[0] + 13}" cy="{ic[1] - 15}" r="9" fill="#fff" stroke="none"/>')
o.extend(g)

svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 800" width="800" height="800">'
       '<rect width="800" height="800" fill="#fff"/><g stroke="#000" stroke-linecap="round">' + "".join(o) + "</g></svg>")
open(sys.argv[1], "w").write(svg)
