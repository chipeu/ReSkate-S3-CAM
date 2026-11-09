#!/usr/bin/env python3
"""Turn a recorder clip into tools/trace/out/clip_data.lua for the testbox replay.

  clip_to_route.py <clip.tsv> [output.lua]
  luau_run -I <plugin> -I tests -I tools/trace/out tests/testbox/routes.lua =clip - 60

The rider's path is exact. Level geometry is only what the clip saw: the ground under the rider, as a plane at each frame.
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from clip import load

KEYS = ["t", "px", "py", "pz", "vx", "vy", "vz", "state", "fx", "fz", "clr", "gy", "nx", "ny", "nz", "gv", "ex", "ey", "ez"]


def main():
    src = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "..", "trace", "out", "clip_data.lua")
    meta, events, frames = load(src)
    s = meta.get("settings", {})
    lines = ["return {", "\tsource = %r," % os.path.basename(src), "\ttrigger = %r, at = %s," % (meta.get("trigger", "?"), meta.get("at", "0")),
             "\tsettings = { trick_pop = %s, crouch = %s, high = %s }," % ("true" if s.get("pop") == "1" else "false", "true" if s.get("crouch") == "1" else "false", "true" if s.get("angle") == "1" else "false"),
             "\tframes = {"]
    for f in frames:
        lines.append("\t\t{" + ",".join(("%g" % f[k]) if k != "t" else ("%.4f" % f[k]) for k in KEYS) + "},")
    lines += ["\t},", "}", ""]
    with open(out, "w", encoding="utf-8") as h:
        h.write("\n".join(lines))
    print("wrote", os.path.normpath(out), len(frames), "frames, trigger", meta.get("trigger"))


if __name__ == "__main__":
    main()
