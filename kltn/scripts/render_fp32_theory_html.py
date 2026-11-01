#!/usr/bin/env python3
"""Render the project's FP32 study guide as print-ready, standalone HTML."""

from html import escape
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "docs" / "fpu_fsm_algorithms_vi.md"
OUTPUT = ROOT / "docs" / "fpu_fsm_algorithms_vi.html"


def inline(source):
    value = escape(source)
    value = re.sub(
        r"\[([^\]]+)\]\(([^)]+)\)",
        lambda match: f'<a href="{escape(match.group(2), quote=True)}">{match.group(1)}</a>',
        value,
    )
    value = re.sub(r"`([^`]+)`", r"<code>\1</code>", value)
    value = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", value)
    value = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", value)
    return value


def split_table(line):
    cells, current, in_code = [], [], False
    for char in line.strip().strip("|"):
        if char == "`":
            in_code = not in_code
        if char == "|" and not in_code:
            cells.append("".join(current).strip())
            current = []
        else:
            current.append(char)
    cells.append("".join(current).strip())
    return [cell.replace("\\|", "|") for cell in cells]   # "\|" is the Markdown escape for a literal bar


def is_special(line):
    return bool(re.match(r"^(#{1,3} |```|\| |[-] |\d+\. )", line))


def render(markdown, deck):
    doc_title = "RV32IF"
    lines = markdown.splitlines()
    html, contents = [], []
    section = 0
    index = 0
    while index < len(lines):
        line = lines[index]
        if not line.strip() or line.startswith("<!--"):   # blank lines and HTML comments (code markers)
            index += 1
            continue
        if line.startswith("```"):
            language = line[3:].strip()
            code = []
            index += 1
            while index < len(lines) and not lines[index].startswith("```"):
                code.append(lines[index])
                index += 1
            html.append(f'<pre class="lang-{escape(language)}"><code>{escape(chr(10).join(code))}</code></pre>')
            index += 1
            continue
        heading = re.match(r"^(#{1,3}) (.+)$", line)
        if heading:
            level, title = len(heading.group(1)), heading.group(2)
            anchor = ""
            if level == 2:
                section += 1
                anchor = f' id="section-{section}"'
                contents.append((section, title))
            html.append(f"<h{level}{anchor}>{inline(title)}</h{level}>")
            if level == 1:
                doc_title = title
                html.append(f'<p class="deck">{escape(deck)}</p>')
                html.append("<TOC_PLACEHOLDER>")
            index += 1
            continue
        if line.startswith("| ") and index + 1 < len(lines) and re.match(r"^\|[\s|:-]+\|$", lines[index + 1]):
            header = split_table(line)
            index += 2
            rows = []
            while index < len(lines) and lines[index].startswith("| "):
                rows.append(split_table(lines[index]))
                index += 1
            columns = len(header)
            html.append(f'<table class="cols-{columns}"><thead><tr>' +
                        "".join(f"<th>{inline(cell)}</th>" for cell in header) +
                        "</tr></thead><tbody>")
            for row in rows:
                html.append("<tr>" + "".join(f"<td>{inline(cell)}</td>" for cell in row) + "</tr>")
            html.append("</tbody></table>")
            continue
        list_match = re.match(r"^(-|\d+\.) (.*)$", line)
        if list_match:
            ordered = list_match.group(1) != "-"
            tag = "ol" if ordered else "ul"
            html.append(f"<{tag}>")
            while index < len(lines):
                match = re.match(r"^(-|\d+\.) (.*)$", lines[index])
                if not match or (match.group(1) != "-") != ordered:
                    break
                html.append(f"<li>{inline(match.group(2))}</li>")
                index += 1
            html.append(f"</{tag}>")
            continue
        paragraph = [line.strip()]
        index += 1
        while index < len(lines) and lines[index].strip() and not is_special(lines[index]):
            paragraph.append(lines[index].strip())
            index += 1
        html.append(f"<p>{inline(' '.join(paragraph))}</p>")

    toc = '<nav class="toc"><div class="toc-title">Nội dung</div><div class="toc-grid">' + "".join(
        f'<a href="#section-{number}">{inline(title)}</a>' for number, title in contents
    ) + "</div></nav>"
    body = "\n".join(html).replace("<TOC_PLACEHOLDER>", toc)
    return """<!doctype html>
<html lang="vi"><head><meta charset="utf-8"><title>""" + escape(doc_title) + """</title>
<style>
@page { size: A4; margin: 14mm 15mm 15mm; }
* { box-sizing: border-box; }
body { font-family: 'Segoe UI', Arial, sans-serif; color: #203046; font-size: 9.7pt; line-height: 1.36; margin: 0; }
h1 { color: #113c6b; font-size: 22pt; line-height: 1.13; margin: 0 0 2mm; }
.deck { color: #55708c; font-size: 11.5pt; margin: 0 0 5mm; }
h2 { color: #164d80; font-size: 14pt; line-height: 1.2; border-bottom: 1.2px solid #7fa9cb; padding-bottom: 1.2mm; margin: 5mm 0 2.2mm; break-after: avoid; }
h3 { color: #2d638e; font-size: 11.3pt; margin: 3.5mm 0 1.2mm; break-after: avoid; }
p { margin: 0 0 2.1mm; orphans: 3; widows: 3; }
ul, ol { margin: 1.2mm 0 2.6mm; padding-left: 6mm; }
li { margin: .8mm 0; break-inside: avoid; }
strong { color: #193e63; }
code { font-family: Consolas, 'Courier New', monospace; font-size: .92em; background: #edf2f7; border-radius: 2px; padding: 0 .8mm; }
pre { font-family: Consolas, 'Courier New', monospace; font-size: 8.7pt; line-height: 1.28; color: #17334f; background: #f1f5f9; border-left: 3px solid #588bb7; padding: 2.6mm 3mm; white-space: pre-wrap; margin: 2mm 0 3mm; break-inside: avoid; }
pre code { background: none; padding: 0; font-size: inherit; }
table { width: 100%; border-collapse: collapse; font-size: 8.6pt; line-height: 1.24; margin: 2mm 0 3mm; table-layout: auto; }
thead { display: table-header-group; }
th, td { border: 1px solid #b7c8d7; text-align: left; vertical-align: top; padding: 1.25mm 1.6mm; overflow-wrap: break-word; }
th { color: #173d63; background: #e5eff7; font-weight: 700; }
tr { break-inside: avoid; }
tr:nth-child(even) td { background: #f7fafc; }
a { color: #1b5f9b; text-decoration: none; }
.toc { border: 1px solid #b9d0e3; border-radius: 5px; padding: 3mm 4mm; background: #f5f9fc; margin: 1mm 0 5mm; break-inside: avoid; }
.toc-title { color: #164d80; font-weight: 700; margin-bottom: 1mm; }
.toc-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1mm 5mm; font-size: 8.8pt; }
</style></head><body>""" + body + "</body></html>"


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Render a study-guide Markdown file as print-ready HTML.")
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--deck", default="Sơ đồ FSM, thuật toán và từng chu kỳ của 26 lệnh RV32F, "
                                          "kèm nguyên lý số đặc biệt, làm tròn và cờ ngoại lệ")
    args = parser.parse_args()
    args.output.write_text(render(args.source.read_text(encoding="utf-8"), args.deck), encoding="utf-8")
    print(args.output)
