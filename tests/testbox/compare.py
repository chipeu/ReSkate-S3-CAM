"""Compare two testbox TSV runs (routes.lua output) and write a Markdown table.

    python tests/testbox/compare.py baseline.tsv candidate.tsv [out.md]
"""
import csv, sys

METRICS = [
    ('airRev', 'Air eye direction reversals', sum),
    ('airHFmm', 'Worst air zig-zag (mm, 3rd difference)', max),
    ('gndHFmm', 'Worst ground zig-zag, rider-relative (mm)', max),
    ('stepcm', 'Worst one-frame eye step vs rider (cm)', max),
    ('yawdeg', 'Worst one-frame yaw (deg)', max),
    ('pitchdeg', 'Worst one-frame pitch (deg)', max),
    ('recovS', 'Longest continuous guard recovery (s)', max),
    ('guardpct', 'Frames inside guard recovery (mean %)', None),
    ('snaps', 'Position snaps caught by the guard', sum),
    ('sweep', 'Final-sweep fallbacks', sum),
    ('restore', 'Full core restores', sum),
    ('errs', 'Plugin or ray errors', sum),
]


def load(path):
    with open(path, encoding='utf8') as f:
        rows = [r for r in csv.DictReader((l for l in f if not l.startswith('F\t')), delimiter='\t')]
    return {(r['route'], r['host'], r['fps'], r['anim']): r for r in rows}


def aggregate(rows, key, how):
    values = [float(r[key]) for r in rows]
    if how is None:
        return sum(values) / max(len(values), 1)
    return how(values)


def main():
    base, cand = load(sys.argv[1]), load(sys.argv[2])
    keys = sorted(set(base) & set(cand))
    lines = [f'Runs compared: {len(keys)} (routes x stepped/rendered root x none/tuck/sink animation x 30/60/144/240 FPS)', '',
             '| Metric | 1.2.18 | Candidate |', '| --- | ---: | ---: |']
    for key, label, how in METRICS:
        a = aggregate([base[k] for k in keys], key, how)
        b = aggregate([cand[k] for k in keys], key, how)
        lines.append(f'| {label} | {a:.2f} | {b:.2f} |')
    lines += ['', 'Worst minimum eye clearance over floors (m): '
              f'{min(float(base[k]["minclr"]) for k in keys):.3f} -> {min(float(cand[k]["minclr"]) for k in keys):.3f}', '']
    lines += ['| Route | Host | 1.2.18 airRev / gndHF / step / recov | Candidate airRev / gndHF / step / recov |', '| --- | --- | ---: | ---: |']
    routes = sorted({(k[0], k[1]) for k in keys})
    for route, host in routes:
        ks = [k for k in keys if k[0] == route and k[1] == host]
        def fmt(table):
            r = [table[k] for k in ks]
            return f"{aggregate(r, 'airRev', sum):.0f} / {aggregate(r, 'gndHFmm', max):.1f} / {aggregate(r, 'stepcm', max):.1f} / {aggregate(r, 'recovS', max):.2f}"
        lines.append(f'| {route} | {host} | {fmt(base)} | {fmt(cand)} |')
    text = '\n'.join(lines) + '\n'
    if len(sys.argv) > 3:
        open(sys.argv[3], 'w', encoding='utf8').write(text)
    print(text)


main()
