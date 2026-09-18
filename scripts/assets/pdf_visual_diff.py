#!/usr/bin/env python3
"""Render two versions of a PDF asset side by side, so a diff can be looked at.

`git diff` with the textconv filter (see pdf_textconv.sh) tells you which numbers
moved; this tells you whether the result is better. Rendering is at device
resolution and upscaled with nearest-neighbour, so what you see are the pixels
macOS will actually draw -- which is the whole point for a 22pt menubar icon.

Two ways to call it. Either two files:

    python3 scripts/assets/pdf_visual_diff.py old.pdf new.pdf

or two git revisions, in which case it finds the PDFs that changed between them:

    python3 scripts/assets/pdf_visual_diff.py                   # HEAD~1 -> working tree
    python3 scripts/assets/pdf_visual_diff.py 06170202 HEAD
    python3 scripts/assets/pdf_visual_diff.py HEAD WORKTREE resources/icons/menubar/menubar-0.pdf

WORKTREE means the file on disk. Writes a PNG (also printing a size table) and,
with --open, reveals it.

Requires: mutool (brew install mupdf-tools), pillow.
"""
import argparse
import io
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("pillow not installed. Run: pip3 install --user --break-system-packages pillow")

REPO = Path(__file__).resolve().parents[2]
WORKTREE = "WORKTREE"


def font(size=13):
    for f in ("/System/Library/Fonts/SFNSMono.ttf", "/System/Library/Fonts/Menlo.ttc",
              "/Library/Fonts/Arial.ttf"):
        try:
            return ImageFont.truetype(f, size)
        except OSError:
            continue
    return ImageFont.load_default()


def git(*args, binary=False):
    r = subprocess.run(["git", "-C", str(REPO), *args], capture_output=True)
    if r.returncode != 0:
        return None
    return r.stdout if binary else r.stdout.decode()


def read_version(rev, path):
    """Bytes of `path` at `rev`, or None if absent there."""
    if rev == WORKTREE:
        f = REPO / path
        return f.read_bytes() if f.is_file() else None
    return git("show", f"{rev}:{path}", binary=True)


def render(pdf_bytes, px_per_pt):
    """Rasterise page 1 at px_per_pt device pixels per point, preserving alpha."""
    if not pdf_bytes:
        return None
    with tempfile.TemporaryDirectory() as td:
        src, out = Path(td) / "in.pdf", Path(td) / "out.png"
        src.write_bytes(pdf_bytes)
        r = subprocess.run(
            ["mutool", "draw", "-o", str(out), "-r", str(72 * px_per_pt), "-c", "rgba", str(src), "1"],
            capture_output=True)
        if r.returncode != 0 or not out.exists():
            return None
        return Image.open(io.BytesIO(out.read_bytes())).convert("RGBA")


def checkerboard(size, cell=8):
    """Neutral backdrop, so transparent areas read as transparent rather than as white ink."""
    img = Image.new("RGBA", size, (255, 255, 255, 255))
    d = ImageDraw.Draw(img)
    for y in range(0, size[1], cell):
        for x in range(0, size[0], cell):
            if (x // cell + y // cell) % 2:
                d.rectangle([x, y, x + cell - 1, y + cell - 1], fill=(228, 228, 228, 255))
    return img


def diff_map(a, b):
    """Changed pixels in red over a ghost of the new version. Returns (image, count)."""
    if a is None or b is None:
        return None, None
    if a.size != b.size:
        b = b.resize(a.size, Image.NEAREST)
    out = Image.new("RGBA", a.size, (255, 255, 255, 255))
    pa, pb, po = a.load(), b.load(), out.load()
    changed = 0
    for y in range(a.size[1]):
        for x in range(a.size[0]):
            if max(abs(pa[x, y][i] - pb[x, y][i]) for i in range(4)) > 8:
                po[x, y] = (220, 30, 60, 255)
                changed += 1
            else:
                v = 255 - int(pb[x, y][3] * 0.18)
                po[x, y] = (v, v, v, 255)
    return out, changed


def upscale(img, target=440):
    f = max(1, round(target / max(img.size)))
    return img.resize((img.size[0] * f, img.size[1] * f), Image.NEAREST)


def flat(img):
    return Image.alpha_composite(checkerboard(img.size), img)


def human(n):
    return "absent" if not n else f"{n:,} B"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("old", nargs="?", default="HEAD~1")
    ap.add_argument("new", nargs="?", default=WORKTREE)
    ap.add_argument("paths", nargs="*")
    ap.add_argument("-o", "--out", default="/tmp/pdf_visual_diff.png")
    ap.add_argument("-s", "--scale", type=int, default=2,
                    help="device pixels per point (2 = retina, the size macOS draws)")
    ap.add_argument("--open", action="store_true", help="open the result when done")
    args = ap.parse_args()

    # File mode: both sides are paths that exist. This is how IntelliJ calls us,
    # since it materialises each revision into a temp file first.
    file_mode = Path(args.old).is_file() and Path(args.new).is_file()
    if file_mode:
        jobs = [(Path(args.new).name,
                 Path(args.old).read_bytes(), Path(args.new).read_bytes())]
        left_title, right_title = "BEFORE", "AFTER"
    else:
        paths = args.paths
        if not paths:
            rng = args.old if args.new == WORKTREE else f"{args.old}..{args.new}"
            paths = [p for p in (git("diff", "--name-only", rng) or "").split()
                     if p.lower().endswith(".pdf")]
        if not paths:
            sys.exit("no changed PDFs between those revisions")
        jobs = [(p, read_version(args.old, p), read_version(args.new, p)) for p in paths]
        left_title, right_title = f"BEFORE  {args.old}", f"AFTER  {args.new}"

    rows, table = [], []
    for name, ob, nb in jobs:
        oi, ni = render(ob, args.scale), render(nb, args.scale)
        if oi is None and ni is None:
            print(f"skip {name}: neither side rendered", file=sys.stderr)
            continue
        dm, changed = diff_map(oi, ni)
        rows.append((name, oi, ni, dm, len(ob or b""), len(nb or b""), changed))
        table.append((name, len(ob or b""), len(nb or b""), changed))
    if not rows:
        sys.exit("nothing to show")

    cells = [upscale(i) for r in rows for i in r[1:4] if i is not None]
    cw, ch = max(c.size[0] for c in cells), max(c.size[1] for c in cells)
    gap, lab, hdr = 18, 34, 26
    W, H = 3 * cw + 4 * gap, hdr + len(rows) * (ch + lab + gap) + gap

    sheet = Image.new("RGBA", (W, H), (255, 255, 255, 255))
    d = ImageDraw.Draw(sheet)
    f, fs = font(14), font(12)
    for i, t in enumerate([left_title, right_title, "CHANGED PIXELS"]):
        d.text((gap + i * (cw + gap), 5), t, fill=(0, 0, 0), font=f)

    for r, (name, oi, ni, dm, ob, nb, changed) in enumerate(rows):
        y = hdr + r * (ch + lab + gap)
        for c, img in enumerate([oi, ni, dm]):
            x = gap + c * (cw + gap)
            if img is None:
                d.text((x, y + ch // 2), "(absent)", fill=(150, 150, 150), font=f)
                continue
            sheet.paste(upscale(flat(img) if c < 2 else img), (x, y))
        delta = f"{nb - ob:+,} B" if ob and nb else ""
        d.text((gap, y + ch + 5), name, fill=(0, 0, 0), font=f)
        d.text((gap, y + ch + 20),
               f"{human(ob)}  ->  {human(nb)}   {delta}"
               + (f"      {changed:,} px changed" if changed is not None else ""),
               fill=(90, 90, 90), font=fs)

    sheet.convert("RGB").save(args.out)

    print(f"{'file':46s} {'before':>10s} {'after':>10s} {'delta':>10s}  changed px")
    for name, ob, nb, changed in table:
        delta = f"{nb - ob:+d}" if ob and nb else "-"
        print(f"{name:46s} {ob:10d} {nb:10d} {delta:>10s}  "
              f"{changed if changed is not None else '-'}")
    print(f"\nwrote {args.out}")
    if args.open:
        subprocess.run(["open", args.out])


if __name__ == "__main__":
    main()
