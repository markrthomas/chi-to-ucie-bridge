#!/usr/bin/env python3
"""
normalize_info.py — fix and report verilator_coverage merged .info files.

verilator_coverage --write-info produces one SF: block per source per .dat
file. Merging a directed-sim .dat (absolute paths) with a cocotb .dat
(relative paths) creates duplicate SF: blocks for the same file with
different path forms. genhtml and verilator_coverage --annotate only see one
block, giving wrong counts.

This script:
  1. Resolves every SF: path to absolute form.
  2. Merges duplicate blocks by summing DA: hit counts.
  3. Writes a clean single-block .info suitable for genhtml.
  4. Optionally prints a per-file text summary (--summary).
  5. Optionally writes annotated source files (--annotate <dir>).

Usage:
  python3 sim/normalize_info.py <input.info> <output.info> [options]

  --root <dir>       Project root for resolving relative SF: paths.
                     Defaults to the parent of this script's directory.
  --summary          Print per-file coverage table to stdout.
  --annotate <dir>   Write annotated source copies to <dir>/.
"""

import sys
import os
import collections

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

def resolve(sf_path, root):
    if os.path.isabs(sf_path):
        return os.path.normpath(sf_path)
    return os.path.normpath(os.path.join(root, sf_path))

def parse_info(path, root):
    """Returns dict: abs_path -> {lineno: hit_count}."""
    data = collections.defaultdict(lambda: collections.defaultdict(int))
    current = None
    with open(path) as f:
        for line in f:
            line = line.rstrip('\n')
            if line.startswith('SF:'):
                current = resolve(line[3:], root)
            elif line.startswith('DA:') and current is not None:
                parts = line[3:].split(',')
                lineno, hits = int(parts[0]), int(parts[1])
                data[current][lineno] += hits
            elif line == 'end_of_record':
                current = None
    return data

def write_info(data, path):
    with open(path, 'w') as f:
        f.write('TN:verilator_coverage\n')
        for sf in sorted(data):
            lines = data[sf]
            f.write(f'SF:{sf}\n')
            lh = 0
            for lineno in sorted(lines):
                hits = lines[lineno]
                f.write(f'DA:{lineno},{hits}\n')
                if hits > 0:
                    lh += 1
            f.write(f'LH:{lh}\n')
            f.write(f'LF:{len(lines)}\n')
            f.write('end_of_record\n')

def print_summary(data, root):
    total_cov, total_lines = 0, 0
    rows = []
    for sf in sorted(data):
        lines = data[sf]
        lh = sum(1 for h in lines.values() if h > 0)
        lf = len(lines)
        pct = 100 * lh // lf if lf else 100
        rel = os.path.relpath(sf, root)
        miss = sorted(ln for ln, h in lines.items() if h == 0)
        rows.append((rel, lh, lf, pct, miss))
        total_cov += lh
        total_lines += lf

    # column widths
    w = max(len(r[0]) for r in rows) + 2
    print(f'\n{"File":<{w}}  {"Hit":>5}  {"Total":>5}  {"Pct":>4}  Uncovered lines')
    print('-' * (w + 32))
    for rel, lh, lf, pct, miss in rows:
        miss_str = ', '.join(str(ln) for ln in miss[:8])
        if len(miss) > 8:
            miss_str += f' (+{len(miss)-8} more)'
        print(f'{rel:<{w}}  {lh:>5}  {lf:>5}  {pct:>3}%  {miss_str}')
    print('-' * (w + 32))
    grand = 100 * total_cov // total_lines if total_lines else 100
    print(f'{"TOTAL":<{w}}  {total_cov:>5}  {total_lines:>5}  {grand:>3}%\n')

def write_annotated(data, out_dir, root):
    os.makedirs(out_dir, exist_ok=True)
    for sf in sorted(data):
        if not os.path.isfile(sf):
            continue
        lines_map = data[sf]
        rel = os.path.relpath(sf, root)
        out_path = os.path.join(out_dir, rel.replace('/', '_'))
        with open(sf) as src, open(out_path, 'w') as dst:
            for i, line in enumerate(src, 1):
                hits = lines_map.get(i)
                if hits is None:
                    dst.write('        ' + line)
                elif hits == 0:
                    dst.write('%000000 ' + line)
                else:
                    dst.write(f'{hits:07d} ' + line)
        print(f'  {out_path}')

def main():
    args = sys.argv[1:]
    root = ROOT
    do_summary = False
    annotate_dir = None

    i = 0
    positional = []
    while i < len(args):
        if args[i] == '--root':
            root = os.path.abspath(args[i+1]); i += 2
        elif args[i] == '--summary':
            do_summary = True; i += 1
        elif args[i] == '--annotate':
            annotate_dir = args[i+1]; i += 2
        else:
            positional.append(args[i]); i += 1

    if len(positional) != 2:
        print(__doc__)
        sys.exit(1)

    src, dst = positional
    data = parse_info(src, root)

    covered = sum(1 for sf in data for h in data[sf].values() if h > 0)
    total = sum(len(data[sf]) for sf in data)
    pct = 100 * covered // total if total else 100
    print(f'[normalize_info] {len(data)} files, {covered}/{total} lines ({pct}%)')

    write_info(data, dst)
    print(f'[normalize_info] wrote {dst}')

    if do_summary:
        print_summary(data, root)

    if annotate_dir:
        print(f'[normalize_info] writing annotated sources to {annotate_dir}/:')
        write_annotated(data, annotate_dir, root)

if __name__ == '__main__':
    main()
