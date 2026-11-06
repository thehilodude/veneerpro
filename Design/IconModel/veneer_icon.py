#!/usr/bin/env python3
"""Generates the Veneer Pro icon model: a squircle tile with three veneer sheets peeling up.

Writes veneer_icon.obj (+ .mtl) in millimeters, Z up, one object per part:
  Base, Veneer_Metal (top), Veneer_Wood (middle), Veneer_Plastic (bottom).
Each sheet covers the tile's upper-left side of an S-shaped edge and curls up along it, revealing
the layer beneath. Sheets have real thickness so edges catch highlights when rendered.

Usage: python3 veneer_icon.py [output.obj]
"""
import math
import sys

# ---- Settings (millimeters) -------------------------------------------------------------------
TILE = 100.0            # tile width and height
SQUIRCLE = 5.0          # superellipse exponent (Apple's app-icon shape is close to 5)
BASE_DEPTH = 8.0        # base slab thickness, below z = 0
SHEET = 0.6             # veneer thickness
GAP = 0.15              # air between stacked sheets
SAMPLES_ALONG = 220     # resolution along each edge
SAMPLES_FLAT = 48       # resolution across the flat part
SAMPLES_CURL = 64       # resolution around the curl

# Each sheet: (name, edge offset across the diagonal, S amplitude, curl radius, curl angle in degrees).
# Edges run along the bottom-left → top-right diagonal; offsets are toward the top-left.
SHEETS = [
    ("Veneer_Plastic", -26.0, 7.0, 7.0, 150.0),   # bottom layer, nearest the lower-right corner
    ("Veneer_Wood",     -3.0, 9.0, 9.0, 165.0),
    ("Veneer_Metal",    19.0, 9.0, 8.0, 150.0),   # top layer
]
COLORS = {
    "Base": (0.80, 0.80, 0.82),
    "Veneer_Plastic": (0.85, 0.87, 0.90),
    "Veneer_Wood": (0.72, 0.50, 0.30),
    "Veneer_Metal": (0.78, 0.79, 0.80),
}

HALF = TILE / 2
S2 = math.sqrt(0.5)


def inside(x, y):
    """Signed test for the squircle: < 1 inside."""
    return (abs(x) / HALF) ** SQUIRCLE + (abs(y) / HALF) ** SQUIRCLE


def to_xy(u, v):
    """Diagonal frame: u runs bottom-left → top-right, v toward the top-left."""
    return (u * S2 - v * S2, u * S2 + v * S2)


def v_extent(u):
    """The v-interval where the line at u lies inside the tile (by bisection), or None."""
    if inside(*to_xy(u, 0.0)) >= 1:
        return None
    def edge(sign):
        lo, hi = 0.0, TILE
        for _ in range(60):
            mid = (lo + hi) / 2
            if inside(*to_xy(u, sign * mid)) < 1:
                lo = mid
            else:
                hi = mid
        return sign * lo
    return edge(-1.0), edge(1.0)


def edge_curve(u, offset, amplitude):
    """An S-shaped edge across the tile."""
    return offset + amplitude * math.sin(math.pi * u / (TILE * 0.62))


def sheet_grid(offset, amplitude, radius, angle):
    """Top-surface points [i][j]: flat from the tile's top-left boundary to the edge, then a curl."""
    u_max = HALF * math.sqrt(2) * 0.999
    # Where the edge lies inside the tile, so the curl can taper to nothing at both ends.
    inner = [u for u in (-u_max + 2 * u_max * k / 2000 for k in range(2001))
             if (ext := v_extent(u)) and ext[0] < edge_curve(u, offset, amplitude) < ext[1]]
    u0, u1 = (min(inner), max(inner)) if inner else (0.0, 0.0)
    grid = []
    for i in range(SAMPLES_ALONG + 1):
        u = -u_max + 2 * u_max * i / SAMPLES_ALONG
        ext = v_extent(u)
        if ext is None:
            continue
        lo, hi = ext
        e = min(max(edge_curve(u, offset, amplitude), lo), hi)
        taper = math.sin(math.pi * (u - u0) / (u1 - u0)) if u1 > u0 and u0 <= u <= u1 else 0.0
        # The curl reaches up to r past the edge; keep it inside the tile.
        r = min(radius * taper ** 0.7, max(e - lo - SHEET, 0.0))
        phi_max = math.radians(angle) * taper ** 0.4
        row = []
        for j in range(SAMPLES_FLAT + 1):            # flat part, top-left boundary → edge
            v = hi + (e - hi) * j / SAMPLES_FLAT
            row.append((*to_xy(u, v), 0.0))
        for j in range(1, SAMPLES_CURL + 1):         # the curl rolls up past the edge, toward the lower right
            phi = phi_max * j / SAMPLES_CURL
            dv = -r * math.sin(phi)
            z = r * (1 - math.cos(phi))
            row.append((*to_xy(u, e + dv), z))
        grid.append(row)
    return grid


def normals(grid):
    """Per-vertex surface normals from neighboring grid points (pointing up on the flat part)."""
    rows, cols = len(grid), len(grid[0])
    out = []
    for i in range(rows):
        line = []
        for j in range(cols):
            a, b = grid[min(i + 1, rows - 1)][j], grid[max(i - 1, 0)][j]
            c, d = grid[i][min(j + 1, cols - 1)], grid[i][max(j - 1, 0)]
            du = [a[k] - b[k] for k in range(3)]
            dv = [c[k] - d[k] for k in range(3)]
            n = [du[1] * dv[2] - du[2] * dv[1], du[2] * dv[0] - du[0] * dv[2], du[0] * dv[1] - du[1] * dv[0]]
            length = math.sqrt(sum(x * x for x in n)) or 1.0
            n = [x / length for x in n]
            line.append(n)
        out.append(line)
    # Orient so the flat part faces up.
    if out[len(out) // 2][0][2] < 0:
        out = [[[-x for x in n] for n in line] for line in out]
    return out


class Mesh:
    def __init__(self):
        self.v, self.n, self.objects = [], [], []

    def add_vertex(self, p, n):
        self.v.append(p)
        self.n.append(n)
        return len(self.v)

    def solid_sheet(self, name, grid, lift):
        """The grid as a closed slab of SHEET thickness: top, bottom and the four edge walls."""
        ns = normals(grid)
        rows, cols = len(grid), len(grid[0])
        top = [[self.add_vertex((p[0], p[1], p[2] + lift), n) for p, n in zip(grid[i], ns[i])] for i in range(rows)]
        bottom = [[self.add_vertex((p[0] - n[0] * SHEET, p[1] - n[1] * SHEET, p[2] - n[2] * SHEET + lift),
                                   [-x for x in n]) for p, n in zip(grid[i], ns[i])] for i in range(rows)]
        faces = []
        for i in range(rows - 1):
            for j in range(cols - 1):
                faces.append((top[i][j], top[i + 1][j], top[i + 1][j + 1], top[i][j + 1]))
                faces.append((bottom[i][j], bottom[i][j + 1], bottom[i + 1][j + 1], bottom[i + 1][j]))
        # Edge walls get their own vertices with face normals, so they shade as crisp edges.
        def wall(a_line, b_line):
            for k in range(len(a_line) - 1):
                quad = [self.v[a_line[k] - 1], self.v[a_line[k + 1] - 1], self.v[b_line[k + 1] - 1], self.v[b_line[k] - 1]]
                e1 = [quad[1][m] - quad[0][m] for m in range(3)]
                e2 = [quad[3][m] - quad[0][m] for m in range(3)]
                n = [e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]]
                length = math.sqrt(sum(x * x for x in n)) or 1.0
                n = [x / length for x in n]
                faces.append(tuple(self.add_vertex(p, n) for p in quad))
        wall([top[0][j] for j in range(cols)], [bottom[0][j] for j in range(cols)])
        wall([bottom[-1][j] for j in range(cols)], [top[-1][j] for j in range(cols)])
        wall([bottom[i][0] for i in range(rows)], [top[i][0] for i in range(rows)])
        wall([top[i][-1] for i in range(rows)], [bottom[i][-1] for i in range(rows)])
        self.objects.append((name, faces))

    def base(self):
        """A squircle slab from z = -BASE_DEPTH to 0."""
        count = 256
        ring = []
        for k in range(count):
            t = 2 * math.pi * k / count
            c, s = math.cos(t), math.sin(t)
            x = HALF * math.copysign(abs(c) ** (2 / SQUIRCLE), c)
            y = HALF * math.copysign(abs(s) ** (2 / SQUIRCLE), s)
            ring.append((x, y))
        top_center = self.add_vertex((0, 0, 0), (0, 0, 1))
        bottom_center = self.add_vertex((0, 0, -BASE_DEPTH), (0, 0, -1))
        top = [self.add_vertex((x, y, 0), (0, 0, 1)) for x, y in ring]
        bottom = [self.add_vertex((x, y, -BASE_DEPTH), (0, 0, -1)) for x, y in ring]
        side_top, side_bottom = [], []
        for k, (x, y) in enumerate(ring):
            # Outward normal of the superellipse.
            nx = math.copysign(abs(x) ** (SQUIRCLE - 1), x)
            ny = math.copysign(abs(y) ** (SQUIRCLE - 1), y)
            length = math.hypot(nx, ny) or 1.0
            n = (nx / length, ny / length, 0)
            side_top.append(self.add_vertex((x, y, 0), n))
            side_bottom.append(self.add_vertex((x, y, -BASE_DEPTH), n))
        faces = []
        for k in range(count):
            m = (k + 1) % count
            faces.append((top_center, top[k], top[m]))
            faces.append((bottom_center, bottom[m], bottom[k]))
            faces.append((side_top[k], side_bottom[k], side_bottom[m], side_top[m]))
        self.objects.append(("Base", faces))

    def write(self, path):
        mtl = path.rsplit(".", 1)[0] + ".mtl"
        with open(mtl, "w") as f:
            for name, (r, g, b) in COLORS.items():
                f.write(f"newmtl {name}\nKd {r} {g} {b}\nKs 0.2 0.2 0.2\nNs 60\n\n")
        with open(path, "w") as f:
            f.write("# Veneer Pro icon model, millimeters, Z up\n")
            f.write(f"mtllib {mtl.rsplit('/', 1)[-1]}\n")
            for x, y, z in self.v:
                f.write(f"v {x:.4f} {y:.4f} {z:.4f}\n")
            for x, y, z in self.n:
                f.write(f"vn {x:.4f} {y:.4f} {z:.4f}\n")
            for name, faces in self.objects:
                f.write(f"o {name}\ng {name}\nusemtl {name}\n")
                for face in faces:
                    f.write("f " + " ".join(f"{i}//{i}" for i in face) + "\n")


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "veneer_icon.obj"
    mesh = Mesh()
    mesh.base()
    for layer, (name, offset, amplitude, radius, angle) in enumerate(SHEETS):
        lift = GAP + SHEET + layer * (SHEET + GAP)
        mesh.solid_sheet(name, sheet_grid(offset, amplitude, radius, angle), lift)
    mesh.write(out)
    print(f"Wrote {out}: {len(mesh.v)} vertices, {sum(len(f) for _, f in mesh.objects)} faces")


if __name__ == "__main__":
    main()
