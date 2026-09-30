#!/usr/bin/env python3
"""What the planes made of what a collector sent them.

    TIMELESS_TEST_METRICS_URL=... TIMELESS_TEST_LOGS_URL=... TIMELESS_TEST_TRACES_URL=... \\
        bench/compression_report.py compression_sent.json [--compact]

What was sent is what bench/compression.exs counted as it sent it. What is
stored is what each plane says of itself, at /select/.../stats.

Without --compact, the planes are as they are: what they have compacted
on their own schedule, and what they have not yet. With it, each is asked
for a backup first, which is how a plane is made to compact everything
it has, and the figures are of a store that has been left alone for a
while.

"raw" is what the plane itself counts a row as before it is compressed:
sixteen bytes for a sample, and the logical bytes of a record or a span.
"""
import json, os, sys, time, urllib.request

PLANES = [
    ("metrics", "TIMELESS_TEST_METRICS_URL", "/select/metrics/stats", 8428),
    ("logs", "TIMELESS_TEST_LOGS_URL", "/select/logsql/stats", 9428),
    ("traces", "TIMELESS_TEST_TRACES_URL", "/select/traces/stats", 10428),
]


def ask(url, method="GET", body=None, timeout=600):
    data = json.dumps(body).encode() if body is not None else (b"" if method == "POST" else None)
    request = urllib.request.Request(url, data=data, method=method)
    if body is not None:
        request.add_header("content-type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as answer:
            text = answer.read().decode()
    except urllib.error.HTTPError as error:
        text = error.read().decode()
    return json.loads(text) if text.strip().startswith("{") else {}


def human(n):
    n = float(n)
    for unit in ["B", "KiB", "MiB", "GiB"]:
        if n < 1024 or unit == "GiB":
            return f"{n:.0f} {unit}" if unit == "B" or n >= 100 else f"{n:.1f} {unit}"
        n /= 1024


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    compact = "--compact" in sys.argv
    sent = json.load(open(args[0])) if args else {}
    stats = {}

    for plane, variable, path, not_on in PLANES:
        url = os.environ.get(variable) or sys.exit(f"{variable} is not set: where are the planes?")
        url = url.rstrip("/")
        if url.endswith(f":{not_on}"):
            sys.exit(f"{variable} is {url}: that is where the planes of this machine are")
        ask(url + "/api/v1/flush", "POST")
        if compact:
            done = ask(url + "/api/v1/backup", "POST", {"destination": f"{plane}-{int(time.time())}.db"})
            if "error" in done:
                sys.exit(f"{plane}: the backup that compacts it failed: {done}")
        stats[plane] = ask(url + path)

    m, l, t = stats["metrics"], stats["logs"], stats["traces"]

    rows = [
        ("samples", sent.get("samples"), sent.get("samples_bytes"),
         m["total_points"], m["raw_ingested_bytes"], m["bytes_on_disk"]),
        ("records", sent.get("records"), sent.get("records_bytes"),
         l["total_entries"], l["raw_ingested_bytes_total"], l["total_bytes"]),
        ("spans", sent.get("spans"), sent.get("spans_bytes"),
         t["total_spans"], t["raw_ingested_bytes_total"], t["bytes_on_disk"]),
    ]

    if sent:
        print(f"{sent['minutes']} minutes, {sent['ticks']} ticks; {sent['processes']} processes, "
              f"{sent['with_series']} with series of their own; "
              f"{sent.get('ended')} ended; {sent['failed_writes']} writes failed, "
              f"{sent['records_let_go']} records let go")
    print("compacted by a backup" if compact else "as the planes have it, on their own schedule")
    print()
    print(f"{'':10} {'stored':>10} {'on the wire':>12} {'each':>8} {'raw':>10} {'each':>8} "
          f"{'on disk':>10} {'each':>8} {'of wire':>8} {'of raw':>7}")

    for name, n_sent, wire, stored, raw, disk in rows:
        if n_sent is not None and n_sent != stored:
            print(f"  ({name}: {n_sent} were sent and {stored} are stored)")
        n = stored or 1
        wire_each = wire / n_sent if n_sent else 0
        print(f"{name:10} {stored:>10} {human(wire or 0):>12} {wire_each:>8.1f} "
              f"{human(raw):>10} {raw / n:>8.1f} {human(disk):>10} {disk / n:>8.2f} "
              f"{(100 * disk / wire if wire else 0):>7.1f}% {100 * disk / raw:>6.1f}%")

    print()
    print(f"metrics: {m['series']} series, {m['chunks']} chunks, "
          f"{m['total_points'] / max(m['chunks'], 1):.1f} samples to a chunk")
    print(f"logs:    {l['compressed_blocks']} blocks compressed and {l['raw_blocks']} not yet, "
          f"{l.get('term_postings', 0)} postings")
    print(f"traces:  {t['compressed_blocks']} blocks compressed and {t['raw_blocks']} not yet, "
          f"{t.get('trace_index_rows', 0)} rows of the index of traces")
    print()
    print(f"{'the file':10} {'pages in use':>13} {'free':>10} {'wal':>10}")
    for plane, s in stats.items():
        used = s["sqlite_page_bytes"] - s["freelist_bytes"]
        print(f"{plane:10} {human(used):>13} {human(s['freelist_bytes']):>10} "
              f"{human(s['database_wal_bytes']):>10}")


main()
