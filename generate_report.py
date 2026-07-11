#!/usr/bin/env python3
"""Generate an HTML performance report (tables + bar charts) from the
results.csv produced by run.sh.

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

# Fixed left-to-right column order for replica modes. Any mode found in the
# CSV that isn't in this list is appended afterwards, in first-seen order.
CANONICAL_MODES = ["1 replica", "1 cross-node replica", "3 replicas"]

# Stable color palette, cycled if there are more series (labels) than colors.
PALETTE = [
    "#e74c3c", "#3498db", "#2ecc71", "#9b59b6", "#f1c40f",
    "#1abc9c", "#e67e22", "#34495e", "#7f8c8d", "#16a085",
    "#8e44ad", "#2980b9", "#27ae60", "#d35400", "#c0392b",
]

# (csv_field, display_name, transform, unit)
METRICS = [
    ("rand_read_iops", "Random Read IOPS", lambda v: v, "IOPS"),
    ("rand_write_iops", "Random Write IOPS", lambda v: v, "IOPS"),
    ("seq_read_kibps", "Sequential Read Throughput", lambda v: v / 1024.0, "MiB/s"),
    ("seq_write_kibps", "Sequential Write Throughput", lambda v: v / 1024.0, "MiB/s"),
    ("rand_read_lat_ns", "Random Read Latency", lambda v: v / 1000.0, "\u00b5s"),
    ("rand_write_lat_ns", "Random Write Latency", lambda v: v / 1000.0, "\u00b5s"),
]


def load_results(csv_path):
    labels = []
    modes = []
    data = OrderedDict()

    if not os.path.exists(csv_path):
        return labels, modes, data

    with open(csv_path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            label = (row.get("label") or "").strip()
            mode = (row.get("replica_mode") or "").strip()
            if not label or not mode:
                continue

            if label not in data:
                data[label] = {}
                labels.append(label)
            if mode not in modes:
                modes.append(mode)

            metrics = {}
            for field, _, transform, _ in METRICS:
                raw = row.get(field, "")
                try:
                    metrics[field] = transform(float(raw))
                except (TypeError, ValueError):
                    metrics[field] = None
            data[label][mode] = metrics

    ordered_modes = [m for m in CANONICAL_MODES if m in modes]
    ordered_modes += [m for m in modes if m not in ordered_modes]

    return labels, ordered_modes, data


def fmt_number(value):
    if value is None:
        return "-"
    return f"{value:,.0f}"


def build_table(title, unit, labels, modes, data, field_read, field_write):
    header_cells = "".join(f'<th colspan="2">{html.escape(m)}</th>' for m in modes)
    sub_header_cells = "".join("<th>Read</th><th>Write</th>" for _ in modes)

    rows = []
    for label in labels:
        cells = []
        for mode in modes:
            metrics = data.get(label, {}).get(mode, {})
            cells.append(
                f"<td>{fmt_number(metrics.get(field_read))}</td>"
                f"<td>{fmt_number(metrics.get(field_write))}</td>"
            )
        rows.append(f'<tr><th class="row-label">{html.escape(label)}</th>{"".join(cells)}</tr>')

    return f"""
    <table class="results-table">
      <caption>{html.escape(title)} ({html.escape(unit)})</caption>
      <thead>
        <tr><th></th>{header_cells}</tr>
        <tr><th></th>{sub_header_cells}</tr>
      </thead>
      <tbody>
        {''.join(rows)}
      </tbody>
    </table>
    """


def build_bar_chart_mpl(title, unit, labels, modes, data, field, colors):
    """Render a grouped bar chart with matplotlib and return it as an inline
    <svg>...</svg> fragment (no XML prolog/DOCTYPE) ready to embed in HTML.
    """
    n_labels = max(len(labels), 1)
    n_modes = max(len(modes), 1)

    fig_width = max(6.0, 1.7 * n_modes + 0.35 * n_labels)
    fig, ax = plt.subplots(figsize=(fig_width, 4.5))

    group_width = 0.8
    bar_width = group_width / n_labels
    x = list(range(n_modes))

    for i, label in enumerate(labels):
        values = [data.get(label, {}).get(mode, {}).get(field) for mode in modes]
        values = [v if v is not None else 0 for v in values]
        offsets = [xi - group_width / 2 + i * bar_width + bar_width / 2 for xi in x]
        ax.bar(offsets, values, width=bar_width * 0.95, label=label, color=colors.get(label, "#999999"))

    ax.set_title(f"{title} ({unit})")
    ax.set_ylabel(unit)
    ax.set_xticks(x)
    ax.set_xticklabels(modes)
    ax.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f"{v:,.0f}"))
    ax.grid(axis="y", linestyle="--", alpha=0.4)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.legend(loc="upper left", bbox_to_anchor=(1.02, 1.0), fontsize=8, borderaxespad=0)

    buf = io.StringIO()
    fig.savefig(buf, format="svg", bbox_inches="tight")
    plt.close(fig)

    svg = buf.getvalue()
    return svg[svg.index("<svg"):]


def build_bar_chart_svg(title, unit, labels, modes, data, field, colors):
    """Pure standard-library fallback renderer, used when matplotlib isn't
    installed. Returns an inline <svg>...</svg> fragment.
    """
    margin_left, margin_top, margin_bottom = 70, 40, 70
    plot_w = 600
    plot_h = 340
    max_label_len = max((len(label) for label in labels), default=10)
    margin_right = min(420, max(160, max_label_len * 7 + 40))
    width = margin_left + plot_w + margin_right
    height = margin_top + plot_h + margin_bottom

    values = [
        data.get(label, {}).get(mode, {}).get(field)
        for label in labels
        for mode in modes
    ]
    values = [v for v in values if v is not None]
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
            v = data.get(label, {}).get(mode, {}).get(field)
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


def build_bar_chart(title, unit, labels, modes, data, field, colors):
    """Renders with matplotlib when available, otherwise falls back to the
    dependency-free SVG renderer."""
    if HAS_MPL:
        return build_bar_chart_mpl(title, unit, labels, modes, data, field, colors)
    return build_bar_chart_svg(title, unit, labels, modes, data, field, colors)


PAGE_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Longhorn Performance Benchmark Report</title>
<style>
  body {{ font-family: -apple-system, Segoe UI, Helvetica, Arial, sans-serif; margin: 24px; color: #222; }}
  h1 {{ margin-bottom: 4px; }}
  .generated-at {{ color: #666; margin-top: 0; margin-bottom: 24px; }}
  h2 {{ border-bottom: 2px solid #ddd; padding-bottom: 6px; margin-top: 40px; }}
  table.results-table {{ border-collapse: collapse; margin: 16px 0 32px; width: 100%; font-size: 13px; }}
  table.results-table caption {{ text-align: left; font-weight: bold; font-size: 14px; margin-bottom: 6px; }}
  table.results-table th, table.results-table td {{ border: 1px solid #ccc; padding: 6px 10px; text-align: right; }}
  table.results-table th.row-label {{ text-align: left; background: #f2e9f7; }}
  table.results-table thead th {{ background: #ecdff5; text-align: center; }}
  table.results-table tbody tr:nth-child(even) {{ background: #fafafa; }}
  .charts-grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(560px, 1fr)); gap: 16px; }}
  .chart-card {{ border: 1px solid #ddd; border-radius: 6px; padding: 8px; }}
  .chart-card svg {{ width: 100%; height: auto; }}
</style>
</head>
<body>
  <h1>Longhorn Performance Benchmark Report</h1>
  <p class="generated-at">Generated at {generated_at} from {csv_path}</p>

  <h2>Summary Tables</h2>
  {tables}

  <h2>Charts</h2>
  <div class="charts-grid">
    {charts}
  </div>
</body>
</html>
"""


def main():
    parser = argparse.ArgumentParser(description="Generate the longhorn-perf-bench HTML report.")
    parser.add_argument("--csv", default="results/results.csv", help="Path to results.csv")
    parser.add_argument("--out", default="results/report.html", help="Path to write report.html")
    args = parser.parse_args()

    out_dir = os.path.dirname(os.path.abspath(args.out))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    labels, modes, data = load_results(args.csv)

    if not labels:
        with open(args.out, "w") as f:
            f.write(
                "<!DOCTYPE html><html><body>"
                "<p>No benchmark results found yet. Run <code>./run.sh run &lt;v1|v2|all&gt;</code> first.</p>"
                "</body></html>"
            )
        print(f"⚠️  No results found in {args.csv}; wrote an empty report to {args.out}")
        return

    if not HAS_MPL:
        print("ℹ️  matplotlib not found; using the built-in SVG renderer. "
              "Run `pip install matplotlib` for nicer charts.")

    colors = {label: PALETTE[i % len(PALETTE)] for i, label in enumerate(labels)}

    tables = "".join(
        build_table(title, unit, labels, modes, data, field_read, field_write)
        for title, unit, field_read, field_write in [
            ("Random IOPS (Read / Write)", "IOPS", "rand_read_iops", "rand_write_iops"),
            ("Sequential Throughput (Read / Write)", "MiB/s", "seq_read_kibps", "seq_write_kibps"),
            ("Random Latency (Read / Write)", "\u00b5s", "rand_read_lat_ns", "rand_write_lat_ns"),
        ]
    )

    charts = "".join(
        f'<div class="chart-card">{build_bar_chart(display, unit, labels, modes, data, field, colors)}</div>'
        for field, display, _, unit in METRICS
    )

    html_doc = PAGE_TEMPLATE.format(
        generated_at=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        csv_path=html.escape(args.csv),
        tables=tables,
        charts=charts,
    )

    with open(args.out, "w") as f:
        f.write(html_doc)

    print(f"✅ Report generated: {os.path.abspath(args.out)}")


if __name__ == "__main__":
    main()
