#!/usr/bin/env python3
"""Per-request inference metrics for the agentic web benchmark.

Adapted from the p100-inference-benchmarks proxy. Differences for this rig:
- normalizes timings from BOTH engines:
    llama.cpp: prompt_n / prompt_per_second / predicted_n / predicted_per_second
    hipfire:   prefill_ms / prefill_tok_s / decode_tok_s (+ usage.completion_tokens)
- the normalized record always carries:
    prompt_n, prompt_per_second, predicted_n, predicted_per_second, engine_raw

Two subcommands sharing one record format:

  proxy      Sit between the agent (pi) and the engine, forward every request
             verbatim, and append one JSON record per completion to a JSONL file.
  summarize  Reduce that JSONL to the per-stage and whole-task figures that go
             into RESULTS.md.

Stage attribution: the orchestrator writes the current stage number into
`<out>.stage`. The proxy reads that file when recording.

Standard library only.
"""

from __future__ import annotations

import argparse
import http.client
import json
import statistics
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def _normalize(timings, payload=None):
    """Map either engine's timings shape onto the canonical record."""
    if not isinstance(timings, dict):
        return None
    prompt_n = timings.get("prompt_n")
    prompt_tps = timings.get("prompt_per_second")
    predicted_n = timings.get("predicted_n")
    predicted_tps = timings.get("predicted_per_second")

    if prompt_n is None and "prefill_tok_s" in timings:
        # hipfire shape
        prompt_tps = timings.get("prefill_tok_s")
        predicted_tps = timings.get("decode_tok_s")
        usage = (payload or {}).get("usage") or {}
        predicted_n = usage.get("completion_tokens")
        prompt_n = usage.get("prompt_tokens")

    if prompt_n is None and predicted_n is None and prompt_tps is None and predicted_tps is None:
        return None
    return {
        "prompt_n": prompt_n,
        "prompt_per_second": prompt_tps,
        "predicted_n": predicted_n,
        "predicted_per_second": predicted_tps,
        "engine_raw": {k: v for k, v in timings.items()
                       if k in ("prefill_ms", "prefill_tok_s", "decode_tok_s",
                                "prompt_n", "prompt_ms", "prompt_per_second",
                                "predicted_n", "predicted_ms", "predicted_per_second",
                                "ttft_ms")},
    }


def _extract_timings(payload):
    if not isinstance(payload, dict):
        return None
    return _normalize(payload.get("timings"), payload)


def _timings_from_sse(chunks):
    for raw in reversed(chunks):
        if raw == "[DONE]":
            continue
        try:
            found = _extract_timings(json.loads(raw))
        except json.JSONDecodeError:
            continue
        if found:
            return found
    return None


def make_handler(upstream_host, upstream_port, out_path):
    stage_path = Path(str(out_path) + ".stage")

    def current_stage():
        try:
            return stage_path.read_text().strip() or "unknown"
        except OSError:
            return "unknown"

    def record(timings, wall_s):
        if not timings:
            return
        row = {"ts": time.time(), "stage": current_stage(), "wall_s": round(wall_s, 3)}
        row.update(timings)
        with open(out_path, "a") as fh:
            fh.write(json.dumps(row) + "\n")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def _forward(self, method):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else None

            conn = http.client.HTTPConnection(upstream_host, upstream_port, timeout=3600)
            headers = {
                k: v
                for k, v in self.headers.items()
                if k.lower() not in ("host", "content-length", "connection")
            }
            if body is not None:
                headers["Content-Length"] = str(len(body))

            started = time.time()
            try:
                conn.request(method, self.path, body=body, headers=headers)
                upstream = conn.getresponse()
            except OSError as exc:
                self.send_error(502, f"upstream unreachable: {exc}")
                conn.close()
                return

            ctype = upstream.getheader("Content-Type", "")
            self.send_response(upstream.status)
            for key, value in upstream.getheaders():
                if key.lower() in ("transfer-encoding", "content-length", "connection"):
                    continue
                self.send_header(key, value)

            if "text/event-stream" in ctype:
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                self._pump_sse(upstream, started)
            else:
                payload = upstream.read()
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                try:
                    record(_extract_timings(json.loads(payload)), time.time() - started)
                except json.JSONDecodeError:
                    pass

            conn.close()

        def _pump_sse(self, upstream, started):
            tail = []
            pending = b""
            while True:
                block = upstream.read(4096)
                if not block:
                    break
                self.wfile.write(b"%X\r\n%s\r\n" % (len(block), block))
                self.wfile.flush()

                pending += block
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    line = line.strip()
                    if line.startswith(b"data:"):
                        tail.append(line[5:].strip().decode("utf-8", "replace"))
                        del tail[:-8]

            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            record(_timings_from_sse(tail), time.time() - started)

        def do_POST(self):
            self._forward("POST")

        def do_GET(self):
            self._forward("GET")

    return Handler


def cmd_proxy(args):
    host, _, port = args.upstream.rpartition(":")
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    handler = make_handler(host, int(port), args.out)
    server = ThreadingHTTPServer(("127.0.0.1", args.listen), handler)
    server.daemon_threads = True
    print(f"metrics proxy :{args.listen} -> {args.upstream}, recording {args.out}", flush=True)
    server.serve_forever()


def _stats(values):
    clean = [v for v in values if isinstance(v, (int, float)) and v > 0]
    if not clean:
        return {"avg": None, "min": None, "max": None, "n": 0}
    return {
        "avg": round(statistics.fmean(clean), 2),
        "min": round(min(clean), 2),
        "max": round(max(clean), 2),
        "n": len(clean),
    }


def _reduce(rows):
    return {
        "requests": len(rows),
        "prompt_tokens": sum(r.get("prompt_n") or 0 for r in rows),
        "generated_tokens": sum(r.get("predicted_n") or 0 for r in rows),
        "prefill_tps": _stats([r.get("prompt_per_second") for r in rows]),
        "decode_tps": _stats([r.get("predicted_per_second") for r in rows]),
        "wall_s": _stats([r.get("wall_s") for r in rows if isinstance(r.get("wall_s"), (int, float))]),
    }


def cmd_summarize(args):
    rows = []
    metrics_file = Path(args.metrics)
    if metrics_file.exists():
        for line in metrics_file.read_text().splitlines():
            line = line.strip()
            if line:
                rows.append(json.loads(line))

    stage_times = json.loads(Path(args.stage_times).read_text()) if args.stage_times else {}

    summary = {
        "label": args.label,
        "engine": args.engine,
        "model": args.model,
        "site_port": args.site_port,
        "total_task_seconds": args.total_seconds,
        "stage_seconds": stage_times,
        "overall": _reduce(rows),
        "stages": {},
    }
    for stage in sorted({r.get("stage", "unknown") for r in rows}):
        summary["stages"][stage] = _reduce([r for r in rows if r.get("stage") == stage])

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(summary, indent=2) + "\n")

    csv_path = Path(args.csv)
    header = (
        "label,engine,model,site_port,total_s,requests,prompt_tokens,generated_tokens,"
        "prefill_avg,prefill_min,prefill_max,decode_avg,decode_min,decode_max\n"
    )
    if not csv_path.exists():
        csv_path.write_text(header)
    o, pf, dc = summary["overall"], summary["overall"]["prefill_tps"], summary["overall"]["decode_tps"]
    with open(csv_path, "a") as fh:
        fh.write(
            f"{args.label},{args.engine},{Path(args.model).name},{args.site_port},"
            f"{args.total_seconds},{o['requests']},{o['prompt_tokens']},{o['generated_tokens']},"
            f"{pf['avg']},{pf['min']},{pf['max']},{dc['avg']},{dc['min']},{dc['max']}\n"
        )

    print(json.dumps(summary, indent=2))
    if o["requests"] == 0:
        print("WARNING: no timings recorded - did the agent reach the proxy?", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("proxy", help="record per-request timings while forwarding")
    p.add_argument("--listen", type=int, required=True)
    p.add_argument("--upstream", required=True, help="host:port of the engine")
    p.add_argument("--out", required=True, help="JSONL output path")
    p.set_defaults(func=cmd_proxy)

    s = sub.add_parser("summarize", help="reduce a JSONL to per-stage figures")
    s.add_argument("--metrics", required=True)
    s.add_argument("--stage-times")
    s.add_argument("--label", required=True)
    s.add_argument("--engine", required=True)
    s.add_argument("--model", required=True)
    s.add_argument("--site-port", type=int, required=True)
    s.add_argument("--total-seconds", type=float, required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--csv", required=True)
    s.set_defaults(func=cmd_summarize)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
