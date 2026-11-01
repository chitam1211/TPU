#!/usr/bin/env python3
"""Keep RTL code excerpts in a Markdown document identical to the RTL sources.

A marker line `<!--code FILE A-B-->` (FILE relative to rtl/core_if, lines A..B 1-based) is
followed by a fenced block. Default mode rewrites that block from the RTL file, with a
first line `// FILE:A-B` citing the source. `--check` only compares and exits 1 on a
mismatch, so a stale excerpt is noticed after the RTL changes.

  python3 scripts/embed_rtl_snippets.py docs/fpu_fsm_algorithms_vi.md
  python3 scripts/embed_rtl_snippets.py --check docs/fpu_fsm_algorithms_vi.md
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl" / "core_if"
MARKER = re.compile(r"^<!--code (\S+) (\d+)-(\d+)-->\s*$")


def block_for(name, first, last):
    path = RTL / name
    if not path.is_file():
        raise SystemExit(f"{name}: not found under {RTL}")
    src = path.read_text(encoding="utf-8").splitlines()
    if not 1 <= first <= last <= len(src):
        raise SystemExit(f"{name}: lines {first}-{last} outside 1..{len(src)}")
    body = [f"// {name}:{first}-{last}"] + [l.rstrip() for l in src[first - 1:last]]
    return ["```verilog"] + body + ["```"]


def process(lines):
    out, changed, i = [], [], 0
    while i < len(lines):
        out.append(lines[i])
        m = MARKER.match(lines[i])
        i += 1
        if not m:
            continue
        name, first, last = m.group(1), int(m.group(2)), int(m.group(3))
        new = block_for(name, first, last)
        j = i
        while j < len(lines) and not lines[j].strip():
            j += 1
        old = []
        if j < len(lines) and lines[j].startswith("```"):
            k = j + 1
            while k < len(lines) and not lines[k].startswith("```"):
                k += 1
            old = lines[j:k + 1]
            i = k + 1
        if old != new:
            changed.append(f"{name}:{first}-{last}")
        out.extend(new)
    return out, changed


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("markdown", type=Path)
    parser.add_argument("--check", action="store_true", help="do not write; exit 1 if any excerpt differs")
    args = parser.parse_args()
    text = args.markdown.read_text(encoding="utf-8")
    out, changed = process(text.splitlines())
    count = sum(1 for l in out if MARKER.match(l))
    if args.check:
        if changed:
            print("Stale RTL excerpts: " + ", ".join(changed))
            return 1
        print(f"OK: {count} RTL excerpts match the sources")
        return 0
    args.markdown.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
    print(f"{count} excerpts embedded, {len(changed)} updated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
