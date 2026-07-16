#!/usr/bin/env python3
"""Generate an HTML performance report and a matching markdown table
(results.md) from the results.csv produced by run.sh.

Charts are rendered with matplotlib (as inline SVG) when it is available,
for nicer-looking output. If matplotlib isn't installed, this script falls
back to a small hand-rolled SVG renderer using only the standard library,
so the report can always be regenerated automatically as the last step of
run.sh with zero manual intervention either way.
"""

from __future__ import annotations

import argparse
import csv
import html
import io
import os
import re
from collections import OrderedDict
from datetime import datetime

try:
    import matplotlib

    matplotlib.use("svg")  # headless backend, no display/X server needed
    import matplotlib.pyplot as plt
    import matplotlib.ticker as mticker

    HAS_MPL = True
except ImportError:
    HAS_MPL = False

try:
    import weasyprint

    HAS_WEASYPRINT = True
except ImportError:
    HAS_WEASYPRINT = False

# Canonical top-to-bottom section order for access modes. Any access mode
# found in the CSV that isn't in this list is appended afterwards, in
# first-seen order.
CANONICAL_ACCESS_MODES = ["ReadWriteOnce", "ReadWriteMany"]

# Access mode assigned to legacy 8-column rows (without an access_mode
# column) - matches the previous default in run.sh.
LEGACY_DEFAULT_ACCESS_MODE = "ReadWriteOnce"

# Fixed left-to-right column order for replica modes. Any mode found in the
# CSV that isn't in this list is appended afterwards, in first-seen order.
CANONICAL_MODES = ["1 replica", "1 cross-node replica", "3 replicas"]

# Chart definitions (one grouped bar chart per entry).
# Fields:
#   key         - stable identifier
#   csv_field   - raw column in results.csv
#   title       - chart title shown to the user
#   scale       - multiplier applied to the raw value for display
#   unit        - unit string shown in the title/axis
CHARTS = [
    dict(key="read_iops",  csv_field="rand_read_iops",   title="Read IOPS",        scale=1 / 1000.0,     unit="k"),
    dict(key="write_iops", csv_field="rand_write_iops",  title="Write IOPS",       scale=1 / 1000.0,     unit="k"),
    dict(key="read_bw",    csv_field="seq_read_kibps",   title="Read Throughput",  scale=1 / 1024.0,     unit="MiB/s"),
    dict(key="write_bw",   csv_field="seq_write_kibps",  title="Write Throughput", scale=1 / 1024.0,     unit="MiB/s"),
    dict(key="read_lat",   csv_field="rand_read_lat_ns", title="Read Latency",     scale=1 / 1000.0,     unit="microseconds"),
    dict(key="write_lat",  csv_field="rand_write_lat_ns",title="Write Latency",    scale=1 / 1000.0,     unit="microseconds"),
]

# Markdown table groups: each has 2 metrics (Read + Write) sharing one caption.
# Fields "read"/"write" reference CHARTS entries by key.
TABLE_GROUPS = [
    dict(caption="IOPS",               read_header="Random Read",  write_header="Random Write",  read="read_iops",  write="write_iops",  scale=1.0,        unit=""),
    dict(caption="Throughput (MiB/s)", read_header="Sequential Read", write_header="Sequential Write", read="read_bw",  write="write_bw", scale=1 / 1024.0, unit=""),
    dict(caption="Latency (\u00b5s)",  read_header="Random Read",  write_header="Random Write",  read="read_lat",   write="write_lat",   scale=1 / 1000.0, unit=""),
]

# Note the two "scale" values above serve different purposes:
# - CHARTS[*].scale is applied when plotting (e.g. IOPS -> k, latency ns -> us).
# - TABLE_GROUPS[*].scale is applied when rendering the tables (e.g. throughput
#   KiB/s -> MiB/s, latency ns -> us). IOPS tables show raw IOPS to match the
#   example screenshot.

# Palette for special series.
COLOR_BASELINE = "#f39c12"   # orange
COLOR_V1       = "#e74c3c"   # red

# Ordered shades from light to dark, used to color v2 series by CPU-core count
# within each bdev-type group. Matches the visual style of the example report.
GREEN_SHADES = ["#c8e6c9", "#81c784", "#4caf50", "#2e7d32", "#1b5e20"]
BLUE_SHADES  = ["#bbdefb", "#64b5f6", "#2196f3", "#1565c0", "#0d47a1"]

# Fallback cycled palette for anything unrecognized.
FALLBACK_PALETTE = [
    "#9b59b6", "#1abc9c", "#e67e22", "#34495e", "#7f8c8d",
    "#16a085", "#8e44ad", "#2980b9", "#27ae60", "#d35400",
]

V2_LABEL_RE = re.compile(
    r"^v2 volume \(.*?(NVMe|AIO) bdev.*?(\d+)\s+CPU core", re.IGNORECASE
)


def load_results(csv_path):
    """Load results.csv grouped by access mode.

    Returns (ordered_access_modes, sections) where sections is an
    OrderedDict mapping access_mode -> {"labels": [...], "modes": [...],
    "raw": OrderedDict(label -> mode -> {csv_field: float})}.

    Legacy 8-column rows (without an access_mode column) are transparently
    tagged with LEGACY_DEFAULT_ACCESS_MODE.
    """
    sections = OrderedDict()

    if not os.path.exists(csv_path):
        return [], sections

    csv_fields = {chart["csv_field"] for chart in CHARTS}

    with open(csv_path, newline="") as f:
        reader = csv.reader(f)
        try:
            header = next(reader)
        except StopIteration:
            return [], sections

        has_access_mode = header and header[0] == "access_mode"
        if has_access_mode:
            data_header = header[1:]
        else:
            data_header = header

        col_idx = {name: i for i, name in enumerate(data_header)}
        label_idx = col_idx.get("label")
        mode_idx = col_idx.get("replica_mode")
        if label_idx is None or mode_idx is None:
            return [], sections

        for raw_row in reader:
            if not raw_row:
                continue
            if has_access_mode:
                access_mode = (raw_row[0] or "").strip() or LEGACY_DEFAULT_ACCESS_MODE
                row = raw_row[1:]
            else:
                access_mode = LEGACY_DEFAULT_ACCESS_MODE
                row = raw_row

            if len(row) <= max(label_idx, mode_idx):
                continue
            label = (row[label_idx] or "").strip()
            mode = (row[mode_idx] or "").strip()
            if not label or not mode:
                continue

            section = sections.setdefault(
                access_mode, {"labels": [], "modes": [], "raw": OrderedDict()}
            )
            if label not in section["raw"]:
                section["raw"][label] = {}
                section["labels"].append(label)
            if mode not in section["modes"]:
                section["modes"].append(mode)

            metrics = {}
            for field in csv_fields:
                i = col_idx.get(field)
                value = row[i] if (i is not None and i < len(row)) else ""
                try:
                    metrics[field] = float(value)
                except (TypeError, ValueError):
                    metrics[field] = None
            section["raw"][label][mode] = metrics

    for section in sections.values():
        ordered = [m for m in CANONICAL_MODES if m in section["modes"]]
        ordered += [m for m in section["modes"] if m not in ordered]
        section["modes"] = ordered

    ordered_access_modes = [am for am in CANONICAL_ACCESS_MODES if am in sections]
    ordered_access_modes += [am for am in sections if am not in ordered_access_modes]

    return ordered_access_modes, sections


def raw_value(raw, label, mode, csv_field):
    return raw.get(label, {}).get(mode, {}).get(csv_field)


def scaled_value(raw, label, mode, csv_field, scale):
    v = raw_value(raw, label, mode, csv_field)
    return v * scale if v is not None else None


def parse_v2(label):
    """Return (bdev_type, cores) if label is a recognizable v2 label, else None."""
    m = V2_LABEL_RE.match(label)
    if not m:
        return None
    return m.group(1), int(m.group(2))


def pick_shade(shades, cores, all_cores):
    """Pick a shade from `shades` (light->dark) based on the position of
    `cores` within the sorted set of `all_cores` seen for this bdev type.

    - Smallest core count -> lightest shade, largest -> darkest.
    - When only one series exists in the group, a medium shade is used so it
      reads clearly on white and visually matches the other color families
      (v1 red, baseline orange).
    """
    ordered = sorted(set(all_cores))
    n = len(ordered)
    if n == 0:
        return shades[len(shades) // 2]
    idx = ordered.index(cores)
    if n == 1:
        return shades[len(shades) // 2]
    # Spread indices evenly across the palette.
    slot = int(round(idx * (len(shades) - 1) / (n - 1)))
    return shades[max(0, min(len(shades) - 1, slot))]


def assign_colors(labels):
    """Assign a color per label: v1 -> red, baseline -> orange, v2 NVMe -> greens
    (light-to-dark by CPU cores), v2 AIO -> blues, others -> cycled palette."""
    v2_by_bdev = {"NVMe": [], "AIO": []}
    for label in labels:
        parsed = parse_v2(label)
        if parsed:
            v2_by_bdev[parsed[0]].append(parsed[1])

    colors = {}
    fallback_idx = 0
    for label in labels:
        if "baseline" in label.lower():
            colors[label] = COLOR_BASELINE
            continue
        if label.strip().lower().startswith("v1 volume"):
            colors[label] = COLOR_V1
            continue
        parsed = parse_v2(label)
        if parsed:
            bdev, cores = parsed
            shades = GREEN_SHADES if bdev == "NVMe" else BLUE_SHADES
            colors[label] = pick_shade(shades, cores, v2_by_bdev[bdev])
            continue
        colors[label] = FALLBACK_PALETTE[fallback_idx % len(FALLBACK_PALETTE)]
        fallback_idx += 1
    return colors


# ---------------------------------------------------------------------------
# Number formatting
# ---------------------------------------------------------------------------

def fmt_number(value):
    if value is None:
        return "-"
    if abs(value) < 10:
        return f"{value:,.2f}"
    return f"{value:,.0f}"


# ---------------------------------------------------------------------------
# Chart rendering (matplotlib preferred, stdlib fallback)
# ---------------------------------------------------------------------------

def build_bar_chart_mpl(title, unit, labels, modes, colors, values_by_label_mode):
    n_labels = max(len(labels), 1)
    n_modes = max(len(modes), 1)

    fig_width = max(6.0, 1.7 * n_modes + 0.35 * n_labels)
    fig, ax = plt.subplots(figsize=(fig_width, 4.5))

    group_width = 0.8
    bar_width = group_width / n_labels
    x = list(range(n_modes))

    for i, label in enumerate(labels):
        values = [values_by_label_mode.get((label, mode)) or 0 for mode in modes]
        offsets = [xi - group_width / 2 + i * bar_width + bar_width / 2 for xi in x]
        ax.bar(offsets, values, width=bar_width * 0.95, label=label, color=colors.get(label, "#999999"))

    ax.set_title(f"{title} ({unit})")
    ax.set_ylabel(unit)
    ax.set_xticks(x)
    ax.set_xticklabels(modes)
    ax.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f"{v:,.0f}" if abs(v) >= 10 else f"{v:.1f}"))
    ax.grid(axis="y", linestyle="--", alpha=0.4)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.legend(loc="upper left", bbox_to_anchor=(1.02, 1.0), fontsize=8, borderaxespad=0)

    buf = io.StringIO()
    fig.savefig(buf, format="svg", bbox_inches="tight")
    plt.close(fig)

    svg = buf.getvalue()
    return svg[svg.index("<svg"):]


def build_bar_chart_svg(title, unit, labels, modes, colors, values_by_label_mode):
    margin_left, margin_top, margin_bottom = 70, 40, 70
    plot_w = 600
    plot_h = 340
    max_label_len = max((len(label) for label in labels), default=10)
    margin_right = min(520, max(160, max_label_len * 7 + 40))
    width = margin_left + plot_w + margin_right
    height = margin_top + plot_h + margin_bottom

    values = [v for v in values_by_label_mode.values() if v is not None]
    max_val = max(values) if values else 1
    if max_val <= 0:
        max_val = 1

    n_modes = max(len(modes), 1)
    n_labels = max(len(labels), 1)
    group_w = plot_w / n_modes
    pad = group_w * 0.08
    usable = group_w - 2 * pad
    bar_w = usable / n_labels

    parts = [f'<svg viewBox="0 0 {width} {height}" xmlns="http://www.w3.org/2000/svg" class="chart-svg">']
    parts.append(f'<rect x="0" y="0" width="{width}" height="{height}" fill="#ffffff"/>')
    parts.append(
        f'<text x="{width / 2:.1f}" y="20" text-anchor="middle" font-size="15" '
        f'font-weight="bold">{html.escape(title)} ({html.escape(unit)})</text>'
    )

    ticks = 5
    for i in range(ticks + 1):
        val = max_val * i / ticks
        y = margin_top + plot_h - (plot_h * i / ticks)
        parts.append(
            f'<line x1="{margin_left}" y1="{y:.1f}" x2="{margin_left + plot_w}" y2="{y:.1f}" '
            f'stroke="#e0e0e0" stroke-width="1"/>'
        )
        parts.append(
            f'<text x="{margin_left - 8}" y="{y + 4:.1f}" text-anchor="end" '
            f'font-size="11" fill="#555">{fmt_number(val)}</text>'
        )

    parts.append(
        f'<line x1="{margin_left}" y1="{margin_top}" x2="{margin_left}" '
        f'y2="{margin_top + plot_h}" stroke="#333" stroke-width="1"/>'
    )
    parts.append(
        f'<line x1="{margin_left}" y1="{margin_top + plot_h}" x2="{margin_left + plot_w}" '
        f'y2="{margin_top + plot_h}" stroke="#333" stroke-width="1"/>'
    )

    for gi, mode in enumerate(modes):
        gx = margin_left + gi * group_w
        for li, label in enumerate(labels):
            v = values_by_label_mode.get((label, mode))
            if v is None:
                continue
            color = colors.get(label, "#999999")
            bx = gx + pad + li * bar_w
            bar_h = plot_h * (v / max_val)
            by = margin_top + plot_h - bar_h
            parts.append(
                f'<rect x="{bx:.1f}" y="{by:.1f}" width="{max(bar_w - 2, 1):.1f}" '
                f'height="{bar_h:.1f}" fill="{color}">'
                f'<title>{html.escape(label)} / {html.escape(mode)}: {fmt_number(v)} {html.escape(unit)}</title>'
                f'</rect>'
            )
        parts.append(
            f'<text x="{gx + group_w / 2:.1f}" y="{margin_top + plot_h + 20}" '
            f'text-anchor="middle" font-size="12" fill="#333">{html.escape(mode)}</text>'
        )

    lx = margin_left + plot_w + 20
    ly = margin_top
    for label in labels:
        color = colors.get(label, "#999999")
        parts.append(f'<rect x="{lx}" y="{ly}" width="12" height="12" fill="{color}"/>')
        parts.append(f'<text x="{lx + 18}" y="{ly + 10}" font-size="11" fill="#333">{html.escape(label)}</text>')
        ly += 18

    parts.append("</svg>")
    return "".join(parts)


def build_bar_chart(title, unit, labels, modes, colors, values_by_label_mode):
    if HAS_MPL:
        return build_bar_chart_mpl(title, unit, labels, modes, colors, values_by_label_mode)
    return build_bar_chart_svg(title, unit, labels, modes, colors, values_by_label_mode)


# ---------------------------------------------------------------------------
# Table rendering (both HTML for report.html and Markdown/HTML for results.md)
# ---------------------------------------------------------------------------

def build_html_table(group, labels, modes, raw):
    caption = group["caption"]
    scale = group["scale"]
    read_field = next(c["csv_field"] for c in CHARTS if c["key"] == group["read"])
    write_field = next(c["csv_field"] for c in CHARTS if c["key"] == group["write"])

    header_top = (
        f'<th colspan="{len(modes)}">{html.escape(group["read_header"])}</th>'
        f'<th colspan="{len(modes)}">{html.escape(group["write_header"])}</th>'
    )
    header_sub = "".join(f"<th>{html.escape(m)}</th>" for m in modes) * 2

    rows = []
    for label in labels:
        cells = []
        for m in modes:
            cells.append(f"<td>{fmt_number(scaled_value(raw, label, m, read_field, scale))}</td>")
        for m in modes:
            cells.append(f"<td>{fmt_number(scaled_value(raw, label, m, write_field, scale))}</td>")
        rows.append(f'<tr><th class="row-label">{html.escape(label)}</th>{"".join(cells)}</tr>')

    return f"""
    <table class="results-table">
      <caption>{html.escape(caption)}</caption>
      <thead>
        <tr><th></th>{header_top}</tr>
        <tr><th></th>{header_sub}</tr>
      </thead>
      <tbody>
        {''.join(rows)}
      </tbody>
    </table>
    """


def build_md_html_table(group, labels, modes, raw):
    """Same structure as build_html_table but standalone HTML for embedding
    inside markdown (GitHub renders raw HTML in .md files, and this is the
    only way to get a two-level header)."""
    scale = group["scale"]
    read_field = next(c["csv_field"] for c in CHARTS if c["key"] == group["read"])
    write_field = next(c["csv_field"] for c in CHARTS if c["key"] == group["write"])

    header_top = (
        f'<th colspan="{len(modes)}" align="center">{html.escape(group["read_header"])}</th>'
        f'<th colspan="{len(modes)}" align="center">{html.escape(group["write_header"])}</th>'
    )
    header_sub = "".join(f'<th align="right">{html.escape(m)}</th>' for m in modes) * 2

    body_rows = []
    for label in labels:
        cells = []
        for m in modes:
            cells.append(f'<td align="right">{fmt_number(scaled_value(raw, label, m, read_field, scale))}</td>')
        for m in modes:
            cells.append(f'<td align="right">{fmt_number(scaled_value(raw, label, m, write_field, scale))}</td>')
        body_rows.append(f"<tr><td>{html.escape(label)}</td>{''.join(cells)}</tr>")

    return (
        "<table>\n"
        "  <thead>\n"
        f"    <tr><th></th>{header_top}</tr>\n"
        f"    <tr><th></th>{header_sub}</tr>\n"
        "  </thead>\n"
        "  <tbody>\n"
        + "".join(f"    {row}\n" for row in body_rows) +
        "  </tbody>\n"
        "</table>\n"
    )


# ---------------------------------------------------------------------------
# Report templates
# ---------------------------------------------------------------------------

PAGE_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<style>
  /* Landscape A3 gives the summary tables and the 2-column chart grid enough
     horizontal room to render without breaking words. Only weasyprint honors
     @page; browsers ignore it, so on-screen HTML stays fluid-width. */
  @page {{ size: A3 landscape; margin: 12mm; }}
  body {{ font-family: -apple-system, Segoe UI, Helvetica, Arial, sans-serif; margin: 24px; color: #222; }}
  h1 {{ margin-bottom: 4px; }}
  .generated-at {{ color: #666; margin-top: 0; margin-bottom: 24px; }}
  h2 {{ border-bottom: 2px solid #444; padding-bottom: 6px; margin-top: 48px; color: #2c3e50;
        page-break-before: always; break-before: page; page-break-after: avoid; break-after: avoid; }}
  h2:first-of-type {{ page-break-before: auto; break-before: auto; }}
  h3 {{ border-bottom: 1px solid #ddd; padding-bottom: 4px; margin-top: 28px;
        page-break-after: avoid; break-after: avoid; }}
  table.results-table {{ border-collapse: collapse; margin: 16px 0 32px; width: 100%; font-size: 13px;
                         table-layout: auto; page-break-inside: avoid; break-inside: avoid; }}
  table.results-table caption {{ text-align: left; font-weight: bold; font-size: 14px; margin-bottom: 6px; }}
  table.results-table th, table.results-table td {{ border: 1px solid #ccc; padding: 6px 10px; text-align: right;
                                                    white-space: nowrap; }}
  table.results-table th.row-label, table.results-table td.row-label {{ text-align: left; background: #f2e9f7;
                                                                        white-space: nowrap; }}
  table.results-table thead th {{ background: #ecdff5; text-align: center; }}
  table.results-table tbody tr:nth-child(even) {{ background: #fafafa; }}
  .charts-grid {{ display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; }}
  .chart-card {{ border: 1px solid #ddd; border-radius: 6px; padding: 8px; min-width: 0;
                 page-break-inside: avoid; break-inside: avoid; }}
  .chart-card svg {{ width: 100%; height: auto; }}
  .section-empty {{ color: #777; font-style: italic; margin: 12px 0 32px; }}
</style>
</head>
<body>
  <h1>{title}</h1>
  <p class="generated-at">Generated at {generated_at}</p>

  {sections}
</body>
</html>
"""

SECTION_TEMPLATE = """  <h2>Access mode: {access_mode}</h2>

  <h3>Summary Tables</h3>
  {tables}

  <h3>Charts</h3>
  <div class="charts-grid">
    {charts}
  </div>
"""


def build_markdown(csv_path, ordered_access_modes, sections, md_out, svg_files_by_am, title):
    """Render results.md with one section per access mode.

    svg_files_by_am is a dict: access_mode -> chart_key -> svg_path.
    """
    generated_at = datetime.now().strftime("%Y-%m-%d")
    parts = [
        f"# {title}\n",
        f"_Generated at {generated_at}._\n",
    ]

    # Compute a relative path from the markdown file to the svg directory so
    # image links keep working regardless of where results/ lives.
    md_dir = os.path.dirname(os.path.abspath(md_out)) if md_out else os.getcwd()

    def rel(svg_path):
        try:
            return os.path.relpath(svg_path, md_dir)
        except ValueError:
            return svg_path

    for access_mode in ordered_access_modes:
        section = sections[access_mode]
        labels = section["labels"]
        modes = section["modes"]
        raw = section["raw"]
        svg_files = svg_files_by_am.get(access_mode, {})

        parts.append(f"\n## Access mode: {access_mode}\n")

        if not labels:
            parts.append("\n_No results recorded for this access mode._\n")
            continue

        for group in TABLE_GROUPS:
            parts.append(f"\n### {group['caption']}\n")
            parts.append(build_md_html_table(group, labels, modes, raw))

            chart_lines = []
            for chart_key, header in ((group["read"], group["read_header"]),
                                      (group["write"], group["write_header"])):
                svg_path = svg_files.get(chart_key)
                if svg_path:
                    chart_lines.append(f"![{header}]({rel(svg_path)})")
            if chart_lines:
                parts.append("\n" + "\n\n".join(chart_lines) + "\n")

    return "".join(parts)


def write_empty_outputs(html_out, md_out, pdf_out, csv_path, title):
    with open(html_out, "w") as f:
        f.write(
            "<!DOCTYPE html><html><body>"
            "<p>No benchmark results found yet. Run <code>./run.sh run &lt;v1|v2|all&gt;</code> first.</p>"
            "</body></html>"
        )
    if md_out:
        with open(md_out, "w") as f:
            f.write(
                f"# {title}\n\n"
                f"_No benchmark results found in `{csv_path}` yet. "
                "Run `./run.sh run <v1|v2|all>` first._\n"
            )
    if pdf_out and os.path.exists(pdf_out):
        try:
            os.remove(pdf_out)
        except OSError:
            pass


_SLUG_RE = re.compile(r"[^A-Za-z0-9]+")


def slugify(name):
    return _SLUG_RE.sub("_", name).strip("_") or "section"


def render_pdf(html_out, pdf_out):
    if not HAS_WEASYPRINT:
        print(
            "\u2139\ufe0f  weasyprint not found; skipping PDF generation. "
            "Run `pip install weasyprint` (or `pip install -r requirements.txt`) to enable it."
        )
        return False
    weasyprint.HTML(filename=html_out).write_pdf(pdf_out)
    print(f"\u2705 PDF report generated: {os.path.abspath(pdf_out)}")
    return True


def main():
    parser = argparse.ArgumentParser(description="Generate the longhorn-perf-bench report.")
    parser.add_argument("--csv", default="results/results.csv", help="Path to results.csv")
    parser.add_argument("--out", default="results/report.html", help="Path to write report.html")
    parser.add_argument("--md",  default="results/results.md",  help="Path to write results.md")
    parser.add_argument("--pdf", default="results/report.pdf",  help="Path to write report.pdf (requires weasyprint)")
    parser.add_argument("--svg-dir", default="results/charts",
                        help="Directory to write one standalone SVG per bar chart (subdirectories per access mode)")
    parser.add_argument("--longhorn-version", default="",
                        help="Longhorn version string (e.g. 'v1.12.0') to include in the report title. "
                             "Typically sourced from `kubectl -n longhorn-system get setting.longhorn.io "
                             "current-longhorn-version -o jsonpath='{.value}'`.")
    args = parser.parse_args()

    report_title = "Longhorn Performance Benchmark Report"
    if args.longhorn_version:
        report_title = f"Longhorn {args.longhorn_version} Performance Benchmark Report"

    for out in (args.out, args.md, args.pdf):
        if not out:
            continue
        out_dir = os.path.dirname(os.path.abspath(out))
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)
    if args.svg_dir:
        os.makedirs(os.path.abspath(args.svg_dir), exist_ok=True)

    ordered_access_modes, sections = load_results(args.csv)

    if not ordered_access_modes:
        write_empty_outputs(args.out, args.md, args.pdf, args.csv, report_title)
        print(f"\u26a0\ufe0f  No results found in {args.csv}; wrote empty {args.out} and {args.md}")
        return

    if not HAS_MPL:
        print("\u2139\ufe0f  matplotlib not found; using the built-in SVG renderer. "
              "Run `pip install matplotlib` for nicer charts.")

    # Build one HTML/Markdown section per access mode, and one SVG subdirectory
    # per access mode so charts from different sections don't overwrite each other.
    svg_files_by_am = {}
    section_htmls = []
    total_svg_count = 0

    for access_mode in ordered_access_modes:
        section = sections[access_mode]
        labels = section["labels"]
        modes = section["modes"]
        raw = section["raw"]

        if not labels:
            section_htmls.append(
                f"  <h2>Access mode: {html.escape(access_mode)}</h2>\n"
                f"  <p class=\"section-empty\">No results recorded for this access mode.</p>\n"
            )
            continue

        colors = assign_colors(labels)

        html_tables = "".join(build_html_table(g, labels, modes, raw) for g in TABLE_GROUPS)
        chart_htmls = []
        svg_files = {}

        am_slug = slugify(access_mode)
        am_svg_dir = os.path.join(os.path.abspath(args.svg_dir), am_slug) if args.svg_dir else None
        if am_svg_dir:
            os.makedirs(am_svg_dir, exist_ok=True)

        for chart in CHARTS:
            values = {
                (label, mode): scaled_value(raw, label, mode, chart["csv_field"], chart["scale"])
                for label in labels
                for mode in modes
            }
            svg = build_bar_chart(chart["title"], chart["unit"], labels, modes, colors, values)
            chart_htmls.append(f'<div class="chart-card">{svg}</div>')

            if am_svg_dir:
                svg_path = os.path.join(am_svg_dir, f"{chart['key']}.svg")
                with open(svg_path, "w") as f:
                    if not svg.lstrip().startswith("<?xml"):
                        f.write('<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n')
                    f.write(svg)
                svg_files[chart["key"]] = svg_path
                total_svg_count += 1

        svg_files_by_am[access_mode] = svg_files
        section_htmls.append(
            SECTION_TEMPLATE.format(
                access_mode=html.escape(access_mode),
                tables=html_tables,
                charts="".join(chart_htmls),
            )
        )

    html_doc = PAGE_TEMPLATE.format(
        title=html.escape(report_title),
        generated_at=datetime.now().strftime("%Y-%m-%d"),
        sections="".join(section_htmls),
    )
    with open(args.out, "w") as f:
        f.write(html_doc)
    print(f"\u2705 HTML report generated: {os.path.abspath(args.out)}")

    if total_svg_count:
        print(f"\u2705 Bar chart SVGs generated in: {os.path.abspath(args.svg_dir)} "
              f"({total_svg_count} files across {len(svg_files_by_am)} access mode(s))")

    if args.md:
        with open(args.md, "w") as f:
            f.write(build_markdown(args.csv, ordered_access_modes, sections, args.md, svg_files_by_am, report_title))
        print(f"\u2705 Markdown report generated: {os.path.abspath(args.md)}")

    if args.pdf:
        render_pdf(args.out, args.pdf)


if __name__ == "__main__":
    main()
