#!/usr/bin/env python3
"""Differential test of `core`: random programs (gen_core_diff.py) run on the reference RTL and
on rtl/core_if, in tb/core_if/tb_core_diff.v. Every retired instruction (pc, instruction, register
written and its value), every store and the final fflags/frm must be identical; only the cycle
count may differ.

The reference is rtl/core_if from a git revision (default af9561e: the core before the fetch and
forwarding changes, verified by ACT4), or a directory given with --ref-dir.
Each program runs with next-cycle memory and with random extra latency on both ports.

Usage (WSL, from kltn/):
  python3 scripts/run_core_diff.py                    # 200 programs x 2 latency settings
  python3 scripts/run_core_diff.py --programs 1000 --count 600
  python3 scripts/run_core_diff.py --seeds 17 42      # rerun given programs
Results: reports/core_diff/results.csv; logs and programs in sim/build/core_diff/.
"""
import argparse
import csv
import io
import shutil
import subprocess
import sys
import tarfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import gen_core_diff  # noqa: E402

TB = ROOT / "tb" / "core_if" / "tb_core_diff.v"
WORK = ROOT / "sim" / "build" / "core_diff"
LATENCY = [(0, 0), (2, 3)]                           # (ilat, dlat) extra cycles


def compile_core(rtl_dir, out):
    sources = sorted(str(p) for p in Path(rtl_dir).glob("*.v"))
    res = subprocess.run(["iverilog", "-g2012", "-Wno-timescale", "-s", "tb_core_diff", "-o", str(out),
                          *sources, str(TB)], capture_output=True, text=True)
    if res.returncode:
        sys.exit(f"compile failed ({rtl_dir}):\n{res.stdout}{res.stderr}")


def ref_rtl(rev):
    """rtl/core_if of a git revision, extracted under WORK."""
    dest = WORK / "ref_rtl"
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=ROOT, capture_output=True,
                         text=True, check=True).stdout.strip()
    prefix = str(ROOT.relative_to(top)) + "/rtl/core_if"
    tar = subprocess.run(["git", "archive", "--format=tar", rev, prefix], cwd=top, capture_output=True, check=True)
    with tarfile.open(fileobj=io.BytesIO(tar.stdout)) as t:
        for m in t.getmembers():
            if m.isfile() and m.name.endswith(".v"):
                (dest / Path(m.name).name).write_bytes(t.extractfile(m).read())
    return dest


def run(sim, case, seed, ilat, dlat):
    res = subprocess.run(["vvp", "-n", str(sim), f"+mem={case / 'mem.hex'}", f"+seed={seed}",
                          f"+ilat={ilat}", f"+dlat={dlat}"], capture_output=True, text=True)
    lines = res.stdout.splitlines()
    cycles = next((int(l.split()[1]) for l in lines if l.startswith("CYCLES")), None)
    # Retires (WB) and stores (MEM) interleave by timing, so each stream is compared on its own.
    body = ([l for l in lines if l.startswith("R ")] + ["-- stores"] +
            [l for l in lines if l.startswith("W ")] + [l for l in lines if l.startswith("END")])
    if cycles is None:
        body.append("NO_END " + ((res.stdout + res.stderr).strip().splitlines() or ["?"])[-1])
    return body, cycles


def check(seed, count, ref_sim, new_sim):
    case = WORK / "programs" / f"p{seed:05d}"
    gen_core_diff.write(case, seed, count)
    rows = []
    for ilat, dlat in LATENCY:
        ref, ref_cyc = run(ref_sim, case, seed, ilat, dlat)
        new, new_cyc = run(new_sim, case, seed, ilat, dlat)
        diff = next((n for n, (x, y) in enumerate(zip(ref, new)) if x != y), None)
        if diff is None and len(ref) != len(new):
            diff = min(len(ref), len(new))
        ok = diff is None and ref_cyc is not None
        note = ""
        if not ok:
            log = case / f"lat{ilat}{dlat}"
            (log.with_suffix(".ref.log")).write_text("\n".join(ref) + "\n")
            (log.with_suffix(".new.log")).write_text("\n".join(new) + "\n")
            d = diff or 0
            note = (f"line {d}: ref '{ref[d] if d < len(ref) else '<end>'}' "
                    f"new '{new[d] if d < len(new) else '<end>'}'")
        retired = sum(1 for l in ref if l.startswith("R "))
        rows.append([seed, ilat, dlat, "PASS" if ok else "FAIL", retired, ref_cyc, new_cyc, note])
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--programs", type=int, default=200)
    ap.add_argument("--first-seed", type=int, default=1)
    ap.add_argument("--seeds", type=int, nargs="*", help="run only these seeds")
    ap.add_argument("--count", type=int, default=400, help="instructions per program")
    ap.add_argument("--ref", default="af9561e",
                    help="git revision of the reference rtl/core_if (default: last core without forwarding)")
    ap.add_argument("--ref-dir", type=Path, help="reference RTL directory instead of --ref")
    ap.add_argument("--jobs", type=int, default=8)
    a = ap.parse_args()

    shutil.rmtree(WORK / "programs", ignore_errors=True)
    WORK.mkdir(parents=True, exist_ok=True)
    ref_dir = a.ref_dir.resolve() if a.ref_dir else ref_rtl(a.ref)
    compile_core(ref_dir, WORK / "ref.out")
    compile_core(ROOT / "rtl" / "core_if", WORK / "new.out")

    seeds = a.seeds or list(range(a.first_seed, a.first_seed + a.programs))
    with ThreadPoolExecutor(a.jobs) as pool:
        results = list(pool.map(lambda s: check(s, a.count, WORK / "ref.out", WORK / "new.out"), seeds))
    rows = [r for rs in results for r in rs]

    rep = ROOT / "reports" / "core_diff"
    rep.mkdir(parents=True, exist_ok=True)
    with open(rep / "results.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["seed", "ilat", "dlat", "status", "retired", "ref_cycles", "new_cycles", "note"])
        w.writerows(rows)

    fails = [r for r in rows if r[3] != "PASS"]
    for r in fails[:10]:
        print(f"FAIL seed {r[0]} lat ({r[1]},{r[2]}): {r[7]}")
        print(f"     program sim/build/core_diff/programs/p{r[0]:05d}/asm.txt")
    for ilat, dlat in LATENCY:
        sel = [r for r in rows if (r[1], r[2]) == (ilat, dlat) and r[3] == "PASS"]
        if sel:
            ref_c, new_c, ret = (sum(r[k] for r in sel) for k in (5, 6, 4))
            print(f"latency +({ilat},{dlat}): {len(sel)} programs, {ret} instructions retired, "
                  f"cycles ref {ref_c} new {new_c} ({new_c / ref_c:.3f}x), CPI ref {ref_c / ret:.2f} new {new_c / ret:.2f}")
    print(f"results : {(rep / 'results.csv').relative_to(ROOT)}")
    print("CORE_DIFF_PASS" if not fails else f"CORE_DIFF_FAIL ({len(fails)} of {len(rows)} runs)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
