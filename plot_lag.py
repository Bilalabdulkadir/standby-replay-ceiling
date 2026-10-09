#!/usr/bin/env python3
"""Draw the standby lag curve written by replay_ceiling.sh as a standalone SVG.

    python3 plot_lag.py lag.csv --load-seconds 43.9 [--title "..."] [-o lag.svg]

Two lines over time since the load started:
  replay lag  = primary WAL position - standby replay position
  receive lag = primary WAL position - standby receive position
If replay lag grows while receive lag stays flat, the standby is replay-bound.
If both grow together, WAL is not reaching the standby fast enough (network or
standby WAL storage), and faster replay would not help.
The shaded band is the load itself. Standard library only.
"""
import argparse
import csv


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--load-seconds", type=float, required=True)
    ap.add_argument("--title", default="Standby lag during a bulk load")
    ap.add_argument("-o", "--output", default="lag.svg")
    a = ap.parse_args()

    rows = list(csv.DictReader(open(a.csv)))
    t = [float(r["seconds"]) for r in rows]
    rep = [float(r["replay_lag_mb"]) for r in rows]
    rcv = [float(r["receive_lag_mb"]) for r in rows]
    if not t:
        raise SystemExit("no samples in " + a.csv)

    w, h, left, right, top, bottom = 760, 360, 64, 20, 44, 48
    tmax = max(t) or 1.0
    ymax = max(max(rep), max(rcv), 1.0) * 1.08

    def x(v):
        return left + (w - left - right) * v / tmax

    def y(v):
        return h - bottom - (h - top - bottom) * v / ymax

    def path(ys):
        return "M" + " L".join("%.1f,%.1f" % (x(a_), y(b_)) for a_, b_ in zip(t, ys))

    out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" font-family="sans-serif" font-size="12">' % (w, h),
           '<rect width="%d" height="%d" fill="#fff"/>' % (w, h),
           '<rect x="%.1f" y="%d" width="%.1f" height="%d" fill="#eef2f7"/>'
           % (x(0), top, x(min(a.load_seconds, tmax)) - x(0), h - top - bottom),
           '<text x="%.1f" y="%d" text-anchor="middle" fill="#667">load (%.0f s)</text>'
           % (x(min(a.load_seconds, tmax) / 2), top + 14, a.load_seconds)]
    for i in range(6):
        v = ymax * i / 5
        out.append('<line x1="%d" x2="%d" y1="%.1f" y2="%.1f" stroke="#ddd"/>' % (left, w - right, y(v), y(v)))
        out.append('<text x="%d" y="%.1f" text-anchor="end" fill="#444">%.0f</text>' % (left - 6, y(v) + 4, v))
    for i in range(6):
        v = tmax * i / 5
        out.append('<text x="%.1f" y="%d" text-anchor="middle" fill="#444">%.0f</text>' % (x(v), h - bottom + 18, v))
    out += ['<path d="%s" fill="none" stroke="#2a7ab0" stroke-width="2"/>' % path(rcv),
            '<path d="%s" fill="none" stroke="#c0392b" stroke-width="2.5"/>' % path(rep),
            '<text x="%d" y="%d" font-size="14" font-weight="bold">%s</text>' % (left, top - 24, a.title),
            '<text x="%d" y="%d" fill="#c0392b">replay lag (MB)</text>' % (left, top - 8),
            '<text x="%d" y="%d" fill="#2a7ab0">receive lag (MB)</text>' % (left + 130, top - 8),
            '<text x="%.1f" y="%d" text-anchor="middle" fill="#444">seconds since the load started</text>'
            % ((left + w - right) / 2, h - 10),
            "</svg>"]
    with open(a.output, "w") as f:
        f.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
