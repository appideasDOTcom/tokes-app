#!/usr/bin/env python3
"""Region-coverage extraction for the Tokes coverage reports.

Usage:
    swift test --enable-code-coverage
    swift test --scratch-path .build-appstore-test -Xswiftc -DTOKES_APP_STORE --enable-code-coverage
    scripts/coverage-regions.py

Prints per-file region coverage for both configurations, the union, the
exclusion row the reports quote, and every union-uncovered region resolved to
file:line:col with its source line.

Method notes (each learned the hard way — see docs/coverage-report-2026-08-19.md
and -2026-08-20.md):
- Export the WHOLE test binary. `llvm-cov export <source-file>` silently drops
  function records whose primary file is elsewhere, which SwiftUI generates
  constantly, producing false zeros.
- A region appears in multiple function records (default-argument thunks,
  specializations). Take the MAX count across records; any single record lies.
- Swift emits no branch data; CodeRegion (kind 0) is the harshest honest metric.
- Even then, region data contains PROVABLE false zeros: ternary arms inside
  call arguments can mis-attribute their counter (AppDelegate.swift:31 — a
  passing assertion proves the arm runs while llvm-cov shows ^0), and stored-
  property default expressions live in `...vpfi` initializer records that never
  tick despite executing at every init. Verify a surprising zero with
  `xcrun llvm-cov show --show-regions` and by reading the tests before calling
  it untested. The uncovered count is an upper bound.
"""
import collections
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "Sources") + os.sep
CONFIGS = {
    "direct": ".build",
    "appstore": ".build-appstore-test",
}
BINARY = "debug/TokesPackageTests.xctest/Contents/MacOS/TokesPackageTests"
PROFDATA = "debug/codecov/default.profdata"
EXCLUDE = ("StatusItemController.swift", "Views/SettingsView.swift", "main.swift")


def regions(scratch):
    binary = os.path.join(ROOT, scratch, BINARY)
    profdata = os.path.join(ROOT, scratch, PROFDATA)
    for p in (binary, profdata):
        if not os.path.exists(p):
            sys.exit(f"missing {p} — run the swift test commands in the docstring first")
    out = subprocess.run(
        ["xcrun", "llvm-cov", "export", binary, "-instr-profile", profdata],
        capture_output=True, check=True)
    best = {}  # (file, ls, cs, le, ce) -> max count across records
    for fn in json.loads(out.stdout)["data"][0]["functions"]:
        files = fn["filenames"]
        for ls, cs, le, ce, cnt, fid, _, kind in fn["regions"]:
            if kind != 0:
                continue
            f = files[fid]
            if not f.startswith(SOURCES):
                continue
            key = (f, ls, cs, le, ce)
            if cnt > best.get(key, -1):
                best[key] = cnt
    return best


def summarize(best, label):
    per = collections.defaultdict(lambda: [0, 0])
    for (f, *_), cnt in best.items():
        per[f][1] += 1
        if cnt > 0:
            per[f][0] += 1
    tot_c = sum(v[0] for v in per.values())
    tot_t = sum(v[1] for v in per.values())
    print(f"== {label}: {tot_c}/{tot_t} = {100 * tot_c / tot_t:.2f}%")
    for f in sorted(per, key=lambda f: per[f][1] - per[f][0], reverse=True):
        c, t = per[f]
        short = f[len(SOURCES):].split("Tokes" + os.sep, 1)[-1]
        print(f"  {short:45s} {c:4d}/{t:<4d} {100 * c / t:6.2f}%  miss {t - c}")
    return per


def main():
    data = {name: regions(scratch) for name, scratch in CONFIGS.items()}
    for name, best in data.items():
        summarize(best, name)
        print()
    keys = set().union(*data.values())
    union = {k: max(d.get(k, 0) for d in data.values()) for k in keys}
    per_u = summarize(union, "union")

    c = sum(v[0] for f, v in per_u.items() if not f.endswith(EXCLUDE))
    t = sum(v[1] for f, v in per_u.items() if not f.endswith(EXCLUDE))
    print(f"\n== union excl {'+'.join(EXCLUDE)}: {c}/{t} = {100 * c / t:.2f}%")

    print("\n== uncovered union regions ==")
    src_cache = {}
    for (f, ls, cs, le, ce) in sorted(k for k, v in union.items() if v == 0):
        short = f[len(SOURCES):].split("Tokes" + os.sep, 1)[-1]
        tags = [n for n, d in data.items() if (f, ls, cs, le, ce) in d]
        tag = "both" if len(tags) == len(data) else f"{tags[0]}-only"
        if f not in src_cache:
            src_cache[f] = open(f).read().splitlines()
        text = src_cache[f][ls - 1].strip() if ls - 1 < len(src_cache[f]) else ""
        print(f"{short}:{ls}:{cs}-{le}:{ce}  [{tag}]  | {text[:100]}")


if __name__ == "__main__":
    main()
