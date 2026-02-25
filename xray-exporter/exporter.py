#!/usr/bin/env python3
"""XRay expvar to Prometheus metrics exporter."""

import json
import os
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler

XRAY_METRICS_URL = os.environ.get("XRAY_METRICS_URL", "http://xray:10085/debug/vars")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9550"))


def fetch_xray_stats():
    try:
        with urllib.request.urlopen(XRAY_METRICS_URL, timeout=5) as resp:
            return json.loads(resp.read())
    except Exception as e:
        print(f"Error fetching xray stats: {e}")
        return None


def format_metrics(data):
    lines = []

    # Traffic stats
    stats = data.get("stats", {})

    for direction in ("inbound", "outbound"):
        entries = stats.get(direction, {})
        for tag, counters in entries.items():
            for link in ("uplink", "downlink"):
                val = counters.get(link, 0)
                metric = f"xray_{direction}_{link}_bytes_total"
                lines.append(f'# TYPE {metric} counter')
                lines.append(f'{metric}{{tag="{tag}"}} {val}')

    user_stats = stats.get("user", {})
    for user, counters in user_stats.items():
        for link in ("uplink", "downlink"):
            val = counters.get(link, 0)
            metric = f"xray_user_{link}_bytes_total"
            lines.append(f'# TYPE {metric} counter')
            lines.append(f'{metric}{{user="{user}"}} {val}')

    # Memory stats
    mem = data.get("memstats", {})
    gauges = {
        "xray_memory_alloc_bytes": mem.get("Alloc", 0),
        "xray_memory_sys_bytes": mem.get("Sys", 0),
        "xray_memory_heap_inuse_bytes": mem.get("HeapInuse", 0),
        "xray_memory_heap_idle_bytes": mem.get("HeapIdle", 0),
    }
    for metric, val in gauges.items():
        lines.append(f"# TYPE {metric} gauge")
        lines.append(f"{metric} {val}")

    num_gc = mem.get("NumGC", 0)
    lines.append("# TYPE xray_gc_cycles_total counter")
    lines.append(f"xray_gc_cycles_total {num_gc}")

    # Up metric
    lines.append("# TYPE xray_up gauge")
    lines.append("xray_up 1")

    return "\n".join(lines) + "\n"


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            data = fetch_xray_stats()
            if data:
                body = format_metrics(data).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
            else:
                body = b"# xray_up 0\nxray_up 0\n"
                self.send_response(503)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
        elif self.path == "/health":
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
        else:
            body = b"Use /metrics\n"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass  # suppress access logs


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", LISTEN_PORT), MetricsHandler)
    print(f"xray-exporter listening on :{LISTEN_PORT}")
    server.serve_forever()
