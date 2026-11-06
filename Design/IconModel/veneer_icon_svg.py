#!/usr/bin/env python3
"""Builds the Veneer Pro icon as a 3D model inside the app-icon outline from an SVG, for KeyShot.

Bodies (each a closed solid, its own OBJ object and material):
  Frame          rounded metal rim following the SVG outline
  Tray           the recessed floor inside the rim
  Sheet_Metal    brushed metal covering the upper left, its edge rolled up
  Sheet_Wood     wood veneer under the metal, its lower-right edge rolled up
  Sheet_Plastic  frosted plastic covering the lower right, its upper-left edge rolled up

Units: 1 SVG unit = 1 mm. X/Y match the SVG viewBox (Y flipped so the top view reads the same), Z up.

Usage: python3 veneer_icon_svg.py AppIcon.svg [output.obj]
"""
import math
import re
import sys

# ---- Settings (SVG units / mm) ----------------------------------------------------------------
TRAY_DEPTH = 50.0       # how far the frame and tray go below the floor (z = 0)
RIM_WIDTH = 28.0        # frame width, inward from the outline
RIM_HEIGHT = 20.0       # top of the rim above the floor
SHEET_INSET = 6.0       # gap between the rim and the sheets
SHEET = 5.0             # sheet thickness
GAP = 1.5               # air between stacked sheets
ALONG, FLAT, CURL = 260, 40, 64   # mesh resolution

# Sheets: (name, side, edge offset, S amplitude, curl radius, curl angle, stack level).
# Offsets run across the diagonal toward the top left. side +1 covers the top-left side of its edge;
# side -1 covers the bottom-right side. Higher levels sit on top.
SHEETS = [
    ("Sheet_Plastic", -1, -215.0, 115.0, 70.0, 150.0, 0),
    ("Sheet_Wood",    +1,    0.0, 130.0, 100.0, 170.0, 1),
    ("Sheet_Metal",   +1,  250.0, 120.0, 95.0, 165.0, 2),
]
MATERIALS = {   # name: (diffuse, specular, shininess, opacity); KeyShot will replace these
    "Frame": ((0.72, 0.72, 0.74), 0.8, 200, 1.0),
    "Tray": ((0.62, 0.62, 0.64), 0.6, 120, 1.0),
    "Sheet_Metal": ((0.80, 0.80, 0.82), 0.9, 250, 1.0),
    "Sheet_Wood": ((0.72, 0.50, 0.30), 0.2, 40, 1.0),
    "Sheet_Plastic": ((0.88, 0.90, 0.93), 0.4, 80, 0.6),
}


# ---- SVG outline ---------------------------------------------------------------------------------
def svg_outline(path, samples=1600):
    """The first path in the SVG, flattened and resampled evenly by length; Y flipped (Y up)."""
    text = open(path).read()
    d = re.search(r'<path[^>]*\sd="([^"]+)"', text).group(1)
    view = [float(v) for v in re.search(r'viewBox="([^"]+)"', text).group(1).split()]
    tokens = re.findall(r'[MmLlHhVvCcSsZz]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?', d)
    pts, i, cmd = [], 0, None
    x = y = 0.0
    last_ctrl = None
    def num():
        nonlocal i
        i += 1
        return float(tokens[i - 1])
    def cubic(p0, p1, p2, p3, n=24):
        for k in range(1, n + 1):
            t = k / n
            a, b, c, e = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t * t, t ** 3
            pts.append((a * p0[0] + b * p1[0] + c * p2[0] + e * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + e * p3[1]))
    while i < len(tokens):
        if re.match(r'[A-Za-z]', tokens[i]):
            cmd = tokens[i]; i += 1
            if cmd in "Zz":
                continue
        rel = cmd.islower()
        c = cmd.upper()
        if c == "M":
            nx, ny = num(), num()
            x, y = (x + nx, y + ny) if rel else (nx, ny)
            pts.append((x, y)); cmd = "l" if rel else "L"; last_ctrl = None
        elif c == "L":
            nx, ny = num(), num()
            x, y = (x + nx, y + ny) if rel else (nx, ny)
            pts.append((x, y)); last_ctrl = None
        elif c == "H":
            nx = num(); x = x + nx if rel else nx; pts.append((x, y)); last_ctrl = None
        elif c == "V":
            ny = num(); y = y + ny if rel else ny; pts.append((x, y)); last_ctrl = None
        elif c in "CS":
            if c == "C":
                c1 = (num(), num())
                if rel: c1 = (x + c1[0], y + c1[1])
            else:
                c1 = (2 * x - last_ctrl[0], 2 * y - last_ctrl[1]) if last_ctrl else (x, y)
            c2, end = (num(), num()), (num(), num())
            if rel:
                c2, end = (x + c2[0], y + c2[1]), (x + end[0], y + end[1])
            cubic((x, y), c1, c2, end)
            last_ctrl, (x, y) = c2, end
    if pts[0] == pts[-1]:
        pts.pop()
    height = view[1] * 2 + view[3]
    pts = [(px, height - py) for px, py in pts]
    # Counterclockwise, then resample evenly.
    if sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(pts, pts[1:] + pts[:1])) < 0:
        pts.reverse()
    lengths = [math.dist(a, b) for a, b in zip(pts, pts[1:] + pts[:1])]
    total, out, k, walked = sum(lengths), [], 0, 0.0
    for s in range(samples):
        target = total * s / samples
        while walked + lengths[k] < target:
            walked += lengths[k]; k += 1
        t = (target - walked) / lengths[k] if lengths[k] else 0
        a, b = pts[k], pts[(k + 1) % len(pts)]
        out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out, view


def inward_normals(poly):
    n = len(poly)
    out = []
    for i in range(n):
        a, b = poly[i - 1], poly[(i + 1) % n]
        tx, ty = b[0] - a[0], b[1] - a[1]
        length = math.hypot(tx, ty) or 1
        out.append((-ty / length, tx / length))   # left of a CCW tangent = inward
    return out


def offset(poly, normals, d):
    return [(p[0] + n[0] * d, p[1] + n[1] * d) for p, n in zip(poly, normals)]


class Shape:
    """Fast inside test for a convex outline around a center, via a radius-by-angle table."""
    def __init__(self, poly, center, bins=7200):
        self.c, self.bins = center, bins
        self.r = [0.0] * bins
        n = len(poly)
        for b in range(bins):
            ang = 2 * math.pi * b / bins
            dx, dy = math.cos(ang), math.sin(ang)
            best = 0.0
            for i in range(n):   # ray / segment intersection
                (x1, y1), (x2, y2) = poly[i], poly[(i + 1) % n]
                ex, ey = x2 - x1, y2 - y1
                den = dx * ey - dy * ex
                if abs(den) < 1e-12:
                    continue
                ox, oy = x1 - center[0], y1 - center[1]
                t = (ox * ey - oy * ex) / den
                s = (ox * dy - oy * dx) / den
                if t > 0 and 0 <= s <= 1:
                    best = t
                    break
            self.r[b] = best

    def inside(self, x, y):
        dx, dy = x - self.c[0], y - self.c[1]
        ang = math.atan2(dy, dx) % (2 * math.pi)
        f = ang / (2 * math.pi) * self.bins
        b0 = int(f) % self.bins
        b1 = (b0 + 1) % self.bins
        r = self.r[b0] + (self.r[b1] - self.r[b0]) * (f - int(f))
        return math.hypot(dx, dy) < r


# ---- Mesh -------------------------------------------------------------------------------------
class Mesh:
    def __init__(self):
        self.v, self.n, self.objects = [], [], []

    def vert(self, p, n):
        self.v.append(p); self.n.append(n)
        return len(self.v)

    def flat_face(self, ps):
        e1 = [ps[1][k] - ps[0][k] for k in range(3)]
        e2 = [ps[-1][k] - ps[0][k] for k in range(3)]
        n = [e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]]
        length = math.sqrt(sum(x * x for x in n)) or 1
        n = [x / length for x in n]
        return tuple(self.vert(p, n) for p in ps)

    def cap(self, ring, z, up):
        """A flat cap over a convex ring (a fan from its centroid)."""
        cx = sum(p[0] for p in ring) / len(ring); cy = sum(p[1] for p in ring) / len(ring)
        n = (0, 0, 1 if up else -1)
        center = self.vert((cx, cy, z), n)
        ids = [self.vert((p[0], p[1], z), n) for p in ring]
        faces = []
        for i in range(len(ring)):
            a, b = ids[i], ids[(i + 1) % len(ring)]
            faces.append((center, a, b) if up else (center, b, a))
        return faces

    def frame(self, poly, normals):
        """Sweep a rounded lip profile around the outline: outer wall, round top, inner wall, bottom."""
        # Profile segments as (inset d, z, normal_d, normal_z); normal_d > 0 points inward.
        R = RIM_WIDTH / 2
        top = RIM_HEIGHT
        arc = []
        for k in range(25):
            t = math.pi * k / 24                    # 0 (outer side) → π (inner side), over the top
            arc.append((R - R * math.cos(t), top - R + R * math.sin(t), -math.cos(t), math.sin(t)))
        segments = [
            [(0.0, -TRAY_DEPTH, -1, 0), (0.0, top - R, -1, 0)],                 # outer wall
            arc,                                                                  # rounded top
            [(RIM_WIDTH, top - R, 1, 0), (RIM_WIDTH, -TRAY_DEPTH, 1, 0)],       # inner wall
            [(RIM_WIDTH, -TRAY_DEPTH, 0, -1), (0.0, -TRAY_DEPTH, 0, -1)],       # bottom
        ]
        faces = []
        count = len(poly)
        for seg in segments:
            rings = []
            for d, z, nd, nz in seg:
                ring = []
                for p, n in zip(poly, normals):
                    pos = (p[0] + n[0] * d, p[1] + n[1] * d, z)
                    nn = (n[0] * nd, n[1] * nd, nz)
                    ring.append(self.vert(pos, nn))
                rings.append(ring)
            for a, b in zip(rings, rings[1:]):
                for i in range(count):
                    j = (i + 1) % count
                    faces.append((a[i], a[j], b[j], b[i]))
        self.objects.append(("Frame", faces))

    def tray(self, ring):
        faces = self.cap(ring, 0.0, True) + self.cap(ring, -TRAY_DEPTH, False)
        for i in range(len(ring)):
            a, b = ring[i], ring[(i + 1) % len(ring)]
            faces.append(self.flat_face([(a[0], a[1], 0.0), (a[0], a[1], -TRAY_DEPTH),
                                         (b[0], b[1], -TRAY_DEPTH), (b[0], b[1], 0.0)]))
        self.objects.append(("Tray", faces))

    def solid_sheet(self, name, grid, lift):
        rows, cols = len(grid), len(grid[0])
        ns = []
        for i in range(rows):
            line = []
            for j in range(cols):
                a, b = grid[min(i + 1, rows - 1)][j], grid[max(i - 1, 0)][j]
                c, d = grid[i][min(j + 1, cols - 1)], grid[i][max(j - 1, 0)]
                du = [a[k] - b[k] for k in range(3)]; dv = [c[k] - d[k] for k in range(3)]
                n = [du[1] * dv[2] - du[2] * dv[1], du[2] * dv[0] - du[0] * dv[2], du[0] * dv[1] - du[1] * dv[0]]
                length = math.sqrt(sum(x * x for x in n)) or 1
                line.append([x / length for x in n])
            ns.append(line)
        flip = ns[rows // 2][0][2] < 0      # the flat part must face up
        if flip:
            ns = [[[-x for x in n] for n in line] for line in ns]
        top = [[self.vert((p[0], p[1], p[2] + lift), n) for p, n in zip(grid[i], ns[i])] for i in range(rows)]
        bottom = [[self.vert((p[0] - n[0] * SHEET, p[1] - n[1] * SHEET, p[2] - n[2] * SHEET + lift),
                             [-x for x in n]) for p, n in zip(grid[i], ns[i])] for i in range(rows)]
        faces = []
        for i in range(rows - 1):
            for j in range(cols - 1):
                q = (top[i][j], top[i + 1][j], top[i + 1][j + 1], top[i][j + 1])
                r = (bottom[i][j], bottom[i][j + 1], bottom[i + 1][j + 1], bottom[i + 1][j])
                if flip:
                    q, r = q[::-1], r[::-1]
                faces += [q, r]
        def wall(a_line, b_line):
            for k in range(len(a_line) - 1):
                quad = [self.v[a_line[k] - 1], self.v[a_line[k + 1] - 1], self.v[b_line[k + 1] - 1], self.v[b_line[k] - 1]]
                faces.append(self.flat_face(quad[::-1] if flip else quad))
        wall([top[0][j] for j in range(cols)], [bottom[0][j] for j in range(cols)])
        wall([bottom[-1][j] for j in range(cols)], [top[-1][j] for j in range(cols)])
        wall([bottom[i][0] for i in range(rows)], [top[i][0] for i in range(rows)])
        wall([top[i][-1] for i in range(rows)], [bottom[i][-1] for i in range(rows)])
        self.objects.append((name, faces))

    def write(self, path):
        mtl = path.rsplit(".", 1)[0] + ".mtl"
        with open(mtl, "w") as f:
            for name, ((r, g, b), ks, ns, d) in MATERIALS.items():
                f.write(f"newmtl {name}\nKd {r} {g} {b}\nKs {ks} {ks} {ks}\nNs {ns}\nd {d}\n\n")
        with open(path, "w") as f:
            f.write("# Veneer Pro icon, 1 unit = 1 mm (SVG units), Z up\n")
            f.write(f"mtllib {mtl.rsplit('/', 1)[-1]}\n")
            for x, y, z in self.v:
                f.write(f"v {x:.4f} {y:.4f} {z:.4f}\n")
            for x, y, z in self.n:
                f.write(f"vn {x:.4f} {y:.4f} {z:.4f}\n")
            for name, faces in self.objects:
                f.write(f"o {name}\ng {name}\nusemtl {name}\n")
                for face in faces:
                    f.write("f " + " ".join(f"{i}//{i}" for i in face) + "\n")


# ---- Sheets -----------------------------------------------------------------------------------
S2 = math.sqrt(0.5)


def build_sheets(mesh, shape, center, span):
    cx, cy = center
    def to_xy(u, v):
        return (cx + u * S2 - v * S2, cy + u * S2 + v * S2)
    def v_extent(u):
        if not shape.inside(*to_xy(u, 0.0)):
            return None
        def edge(sign):
            lo, hi = 0.0, span
            for _ in range(40):
                mid = (lo + hi) / 2
                if shape.inside(*to_xy(u, sign * mid)): lo = mid
                else: hi = mid
            return sign * lo
        return edge(-1.0), edge(1.0)
    u_max = span * 0.999
    extents = {}
    def ext(u):
        key = round(u, 6)
        if key not in extents: extents[key] = v_extent(u)
        return extents[key]
    for name, side, off, amp, radius, angle, level in SHEETS:
        def edge_v(u): return off + amp * math.sin(math.pi * u / (span * 0.88))
        inner = [u for u in (-u_max + 2 * u_max * k / 1200 for k in range(1201))
                 if (e := ext(u)) and e[0] < edge_v(u) < e[1]]
        u0, u1 = (min(inner), max(inner)) if inner else (0, 0)
        grid = []
        for i in range(ALONG + 1):
            u = -u_max + 2 * u_max * i / ALONG
            e = ext(u)
            if e is None:
                continue
            lo, hi = e
            ev = min(max(edge_v(u), lo), hi)
            taper = math.sin(math.pi * (u - u0) / (u1 - u0)) if u1 > u0 and u0 <= u <= u1 else 0.0
            room = (ev - lo) if side > 0 else (hi - ev)
            r = min(radius * taper ** 0.7, max(room - SHEET, 0.0))
            phi_max = math.radians(angle) * taper ** 0.4
            start = hi if side > 0 else lo
            row = [(*to_xy(u, start + (ev - start) * j / FLAT), 0.0) for j in range(FLAT + 1)]
            for j in range(1, CURL + 1):
                phi = phi_max * j / CURL
                row.append((*to_xy(u, ev - side * r * math.sin(phi)), r * (1 - math.cos(phi))))
            grid.append(row)
        lift = SHEET + GAP + level * (SHEET + GAP)
        mesh.solid_sheet(name, grid, lift)


def main():
    svg = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "VeneerIcon.obj"
    outline, view = svg_outline(svg)
    normals = inward_normals(outline)
    xs = [p[0] for p in outline]; ys = [p[1] for p in outline]
    center = ((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2)
    mesh = Mesh()
    mesh.frame(outline, normals)
    mesh.tray(offset(outline[::4], normals[::4], RIM_WIDTH + 0.5))
    sheet_area = offset(outline, normals, RIM_WIDTH + SHEET_INSET)
    span = (max(xs) - min(xs)) * 0.75
    build_sheets(mesh, Shape(sheet_area[::2], center), center, span)
    mesh.write(out)
    print(f"Wrote {out}: {len(mesh.v)} vertices, {sum(len(f) for _, f in mesh.objects)} faces, "
          f"bounds X {min(xs):.1f}–{max(xs):.1f}  Y {min(ys):.1f}–{max(ys):.1f}")


if __name__ == "__main__":
    main()
