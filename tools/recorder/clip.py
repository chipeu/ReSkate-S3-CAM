#!/usr/bin/env python3
"""Read Dynamic Camera recorder clips.

  clip.py show <file> [seconds]   summary and a per-frame timeline around the trigger (default 0.35 s each side)
  clip.py watch [folder]          print a summary of each new clip as it appears; stops with Ctrl+C
  clip.py latest [folder]         the same summary for the newest clip

The folder is <game>/Mods/.reskate_plugin_data/aescher-Dynamic_Camera/recorder. Without one, DYNCAM_CLIP_DIR is used.
"""
import glob, math, os, sys, time

TEXT = {"shot", "cause"}


def clip_folder():
    folder = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("DYNCAM_CLIP_DIR")
    if not folder:
        sys.exit("Give the recorder folder as an argument or in DYNCAM_CLIP_DIR")
    return folder


def load(path):
    meta, events, frames, cols = {}, [], [], None
    with open(path, encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("#"):
                words = line[1:].split()
                kv = dict(w.split("=", 1) for w in words if "=" in w)
                if words and words[0] == "event":
                    events.append(kv)
                elif words and words[0] == "settings":
                    meta["settings"] = kv
                else:
                    meta.update(kv)
            elif cols is None:
                cols = line.split("\t")
            else:
                parts = line.split("\t")
                if len(parts) == len(cols):
                    frames.append({c: (p if c in TEXT else float(p)) for c, p in zip(cols, parts)})
    return meta, events, frames


def wrap(a):
    return (a + 180) % 360 - 180


def summary(path, window=0.35):
    meta, events, frames = load(path)
    print("=" * 96)
    print(os.path.basename(path), "| version", meta.get("version"), "| trigger", meta.get("trigger"), "value", meta.get("value"))
    print("settings", " ".join("%s=%s" % kv for kv in meta.get("settings", {}).items()))
    if not frames:
        print("no frames")
        return
    at = float(meta.get("at", frames[0]["t"]))
    span = frames[-1]["t"] - frames[0]["t"]
    print("frames %d over %.2f s (%.0f FPS) | events %s" % (len(frames), span, (len(frames) - 1) / max(span, 1e-6),
          ", ".join("%s@%+.2f=%s" % (e["name"], float(e["t"]) - at, e["value"]) for e in events)))
    changes, last = [], None
    for f in frames:
        if f["state"] != last:
            changes.append("%+.2f:%d" % (f["t"] - at, f["state"]))
            last = f["state"]
    print("states", " ".join(changes[:24]))
    behind = sum(f["depth"] <= 0.3 for f in frames)
    yaw = rate = 0
    for a, b in zip(frames, frames[1:]):
        if b["cont"]:
            yaw = max(yaw, abs(wrap(b["yaw"] - a["yaw"])))
    print("peaks | rider behind frames %d | min depth %.2f | max orbit %.1f | max yaw step %.2f | max guard %.2f | max align %.2f | max pull %.2f | max lift %.1f | min pitch %.1f" % (
        behind, min(f["depth"] for f in frames), max(abs(f["orb"]) for f in frames), yaw,
        max(f["guard"] for f in frames), max(f["align"] for f in frames), max(f["pull"] for f in frames),
        max(f["lift"] for f in frames), min(f["pitch"] for f in frames)))
    print("   rel    st shot          spd   yaw  cyaw  pitch  orb c trick  dist depth    sx    sy guard align  pull  lift flags")
    prev = None
    for f in frames:
        rel = f["t"] - at
        if abs(rel) <= window:
            yaw_step = wrap(f["yaw"] - prev["yaw"]) if prev else 0
            speed = math.hypot(f["vx"], f["vz"])
            print("%+7.3f %3d %-12s %5.1f %6.1f %6.1f %6.1f %5.1f %d %5.1f %5.2f %5.2f %5.2f %5.2f %5.2f %5.2f %5.2f %5.1f %5d %s" % (
                rel, f["state"], f["shot"][:12], speed, f["yaw"], f["cyaw"], f["pitch"], f["orb"], f["con"], f["trick"], f["dist"],
                f["depth"], f["sx"], f["sy"], f["guard"], f["align"], f["pull"], f["lift"], f["flags"], ("step %+.1f" % yaw_step) if abs(yaw_step) > 3 else ""))
        prev = f
    sys.stdout.flush()


def clips(folder):
    return sorted(glob.glob(os.path.join(folder, "rec_*.tsv")))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "latest"
    if cmd == "show":
        summary(sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 0.35)
    elif cmd == "latest":
        found = clips(clip_folder())
        if found:
            summary(found[-1])
        else:
            print("no clips")
    elif cmd == "watch":
        folder = clip_folder()
        seen = set(clips(folder))
        print("watching", folder, "| existing clips", len(seen), flush=True)
        while True:
            for path in clips(folder):
                if path not in seen:
                    seen.add(path)
                    summary(path)
            time.sleep(1.0)
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
