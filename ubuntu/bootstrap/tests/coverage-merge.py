#!/usr/bin/env python3
"""Merge kcov cobertura.xml reports of many runs: a line counts as covered when any run covered it.

Usage: coverage-merge.py DIR [--min PERCENT]
Prints the total percentage and a per-file table; exits 1 when the total is below --min.
"""
import pathlib, sys, xml.etree.ElementTree as ET

root = pathlib.Path(sys.argv[1])
minimum = float(sys.argv[sys.argv.index('--min') + 1]) if '--min' in sys.argv else 0.0
lines = {}  # file -> {line: hit}
for xml in root.rglob('cobertura.xml'):
    try:
        tree = ET.parse(xml)
    except ET.ParseError:
        continue
    for cls in tree.iter('class'):
        name = cls.get('filename') or cls.get('name')
        if not name or '/tests/' in name or name.endswith('/install.sh') and 'opt/ubuntu-bootstrap' not in name:
            continue
        name = name.replace('/opt/ubuntu-bootstrap/', '').replace('/src/', '')
        if name.startswith('tests/'):
            continue
        store = lines.setdefault(name, {})
        for line in cls.iter('line'):
            n = int(line.get('number'))
            store[n] = store.get(n, 0) or int(line.get('hits', '0')) > 0

total = covered = 0
rows = []
for name in sorted(lines):
    t = len(lines[name]); c = sum(1 for v in lines[name].values() if v)
    total += t; covered += c
    rows.append((100.0 * c / t if t else 0.0, c, t, name))
pct = 100.0 * covered / total if total else 0.0
for p, c, t, name in sorted(rows):
    print(f'{p:6.1f}%  {c:4d}/{t:<4d}  {name}')
print(f'\nTotal: {pct:.1f}% lines ({covered}/{total}) over {len(rows)} files, reports: {sum(1 for _ in root.rglob("cobertura.xml"))}')
sys.exit(0 if pct >= minimum else 1)
