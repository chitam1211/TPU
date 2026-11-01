#!/usr/bin/env python3
"""Render a Markdown study document to print-ready HTML with Verilog syntax highlighting.

Supports the subset used in docs/*.md: #..#### headings, paragraphs, pipe tables,
- and 1. lists, fenced code (```verilog is highlighted with pygments, other fences are
plain), inline `code`, **bold**, *italic* and [links](url). Lines starting with <!--
(RTL excerpt markers) are skipped. Print the HTML to PDF with a headless browser:

  python3 scripts/render_doc_html.py docs/giai_thich_fpu_core_if.md /tmp/out.html
  msedge --headless=new --no-pdf-header-footer --print-to-pdf=out.pdf file:///.../out.html
"""
import re
import sys
from html import escape
from pathlib import Path

from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import VerilogLexer

FORMATTER = HtmlFormatter(style="friendly", nowrap=True)


def inline(source):
    value = escape(source)
    value = re.sub(r"\[([^\]]+)\]\(([^)]+)\)",
                   lambda m: f'<a href="{escape(m.group(2), quote=True)}">{m.group(1)}</a>', value)
    value = re.sub(r"`([^`]+)`", r"<code>\1</code>", value)
    value = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", value)
    value = re.sub(r"(?<![\*\w])\*([^*\s][^*]*)\*(?![\*\w])", r"<em>\1</em>", value)
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
    return [c.replace("\\|", "|") for c in cells]


SPECIAL = re.compile(r"^(#{1,4} |```|\| |- |\d+\. )")


def render(markdown):
    lines = markdown.splitlines()
    out, toc, title = [], [], "Document"
    n2 = 0
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip() or line.startswith("<!--"):
            i += 1
            continue
        if line.startswith("```"):
            lang = line[3:].strip()
            body = []
            i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                body.append(lines[i])
                i += 1
            i += 1
            text = "\n".join(body)
            if lang == "verilog":
                out.append(f'<pre class="code hl">{highlight(text, VerilogLexer(), FORMATTER)}</pre>')
            else:
                out.append(f'<pre class="code">{escape(text)}</pre>')
            continue
        m = re.match(r"^(#{1,4}) (.+)$", line)
        if m:
            level, text = len(m.group(1)), m.group(2)
            anchor = ""
            if level == 1:
                title = re.sub(r"`", "", text)
            if level == 2:
                n2 += 1
                anchor = f' id="s{n2}"'
                toc.append((n2, text))
            out.append(f"<h{level}{anchor}>{inline(text)}</h{level}>")
            if level == 1:
                out.append("<TOC>")
            i += 1
            continue
        if line.startswith("| ") and i + 1 < len(lines) and re.match(r"^\|[\s|:-]+\|$", lines[i + 1]):
            head = split_table(line)
            aligns = ["right" if c.strip().endswith(":") else "left" for c in split_table(lines[i + 1])]
            i += 2
            rows = []
            while i < len(lines) and lines[i].startswith("| "):
                rows.append(split_table(lines[i]))
                i += 1
            html = ['<table><thead><tr>' + "".join(f'<th style="text-align:{a}">{inline(c)}</th>'
                                                   for c, a in zip(head, aligns)) + "</tr></thead><tbody>"]
            for r in rows:
                html.append("<tr>" + "".join(f'<td style="text-align:{a}">{inline(c)}</td>'
                                             for c, a in zip(r, aligns)) + "</tr>")
            out.append("".join(html) + "</tbody></table>")
            continue
        m = re.match(r"^(-|\d+\.) (.*)$", line)
        if m:
            ordered = m.group(1) != "-"
            tag = "ol" if ordered else "ul"
            items = []
            while i < len(lines):
                mm = re.match(r"^(-|\d+\.) (.*)$", lines[i])
                if not mm or (mm.group(1) != "-") != ordered:
                    break
                items.append(f"<li>{inline(mm.group(2))}</li>")
                i += 1
            out.append(f"<{tag}>" + "".join(items) + f"</{tag}>")
            continue
        para = [line.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() and not SPECIAL.match(lines[i]) \
                and not lines[i].startswith("<!--"):
            para.append(lines[i].strip())
            i += 1
        out.append(f"<p>{inline(' '.join(para))}</p>")
    entries = [(n, inline(re.sub(r"^\d+\. ", "", t))) for n, t in toc]
    toc_html = '<nav class="toc"><div class="toc-title">Mục lục</div><ol>' + "".join(
        f'<li><a href="#s{n}">{t}</a></li>' for n, t in entries) + "</ol></nav>"
    body = "\n".join(out).replace("<TOC>", toc_html)
    css = FORMATTER.get_style_defs(".hl")
    return f"""<!doctype html><html lang="vi"><head><meta charset="utf-8"><title>{escape(title)}</title>
<style>
@page {{ size: A4; margin: 15mm 15mm 16mm; }}
* {{ box-sizing: border-box; }}
body {{ font-family: 'DejaVu Sans', 'Noto Sans', 'Segoe UI', sans-serif; color: #1f2a37; font-size: 9.6pt;
       line-height: 1.5; margin: 0; }}
h1 {{ font-size: 20pt; color: #12355b; margin: 0 0 3mm; line-height: 1.2; }}
h2 {{ font-size: 14.5pt; color: #12355b; border-bottom: 1.4px solid #8fb0cf; padding-bottom: 1.2mm;
      margin: 7mm 0 2.5mm; break-after: avoid; page-break-before: always; }}
h3 {{ font-size: 11.6pt; color: #1f4f7c; margin: 5mm 0 1.5mm; break-after: avoid; }}
h4 {{ font-size: 10.2pt; color: #2e5f8a; margin: 3.5mm 0 1mm; break-after: avoid; }}
p {{ margin: 0 0 2.2mm; text-align: justify; orphans: 3; widows: 3; }}
ol, ul {{ margin: 1mm 0 2.6mm; padding-left: 7mm; }}
li {{ margin: .6mm 0; }}
ol li::marker {{ font-variant-numeric: tabular-nums; }}
code {{ font-family: 'DejaVu Sans Mono', Consolas, monospace; font-size: .86em; background: #eef2f6;
        border-radius: 2px; padding: 0 .7mm; }}
pre.code {{ font-family: 'DejaVu Sans Mono', Consolas, monospace; font-size: 7.9pt; line-height: 1.32;
            background: #f6f8fa; border: 1px solid #dde3ea; border-left: 3px solid #5b8bb8;
            padding: 2.4mm 3mm; white-space: pre-wrap; margin: 2mm 0 3mm; }}
pre.code code {{ background: none; padding: 0; }}
table {{ border-collapse: collapse; width: 100%; font-size: 8.3pt; margin: 2mm 0 3.2mm;
         font-variant-numeric: tabular-nums; }}
th, td {{ border: 1px solid #c3d0dc; padding: 1.1mm 1.6mm; vertical-align: top; }}
th {{ background: #e7eff7; color: #173d63; }}
td code, th code {{ font-size: .92em; }}
tr {{ break-inside: avoid; }}
a {{ color: #1b5f9b; text-decoration: none; }}
.toc {{ border: 1px solid #c3d0dc; background: #f5f9fc; padding: 3mm 4mm; margin: 2mm 0 4mm; }}
.toc-title {{ font-weight: bold; color: #12355b; margin-bottom: 1mm; }}
.toc ol {{ columns: 2; margin: 0; }}
{css}
</style></head><body>
{body}
</body></html>"""


if __name__ == "__main__":
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    dst.write_text(render(src.read_text(encoding="utf-8")), encoding="utf-8")
    print(dst)
