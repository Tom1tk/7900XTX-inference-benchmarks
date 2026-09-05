#!/usr/bin/env python3
"""Mixed-workload decode benchmark against a running llama-server.

Usage: python3 bench_mix.py --port 8093 --log /tmp/opencode/srv.log --label V2-32k [--runs 3]

Measures decode tok/s per workload class (code / prose / tool-call / mixed),
parsing the server's own print_timing lines. Fresh prompts, temp 0.
"""
import argparse, json, re, statistics, subprocess, time, urllib.request

def timing_lines(log_path, since_bytes):
    with open(log_path, 'rb') as f:
        f.seek(since_bytes)
        data = f.read().decode('utf-8', 'replace')
    out = []
    for m in re.finditer(r'eval time =\s+([\d.]+) ms /\s+(\d+) tokens.*?([\d.]+) tokens per second', data):
        out.append(('eval', float(m.group(1)), int(m.group(2)), float(m.group(3))))
    for m in re.finditer(r'prompt eval time =\s+([\d.]+) ms /\s+(\d+) tokens.*?([\d.]+) tokens per second', data):
        out.append(('prefill', float(m.group(1)), int(m.group(2)), float(m.group(3))))
    for m in re.finditer(r'draft acceptance = ([\d.]+).*?mean len =\s+([\d.]+)', data):
        out.append(('accept', float(m.group(1)), float(m.group(2)), None))
    return out, log_path_size(log_path)

def log_path_size(p):
    import os
    return os.path.getsize(p)

def chat(port, content, max_tokens=256):
    body = json.dumps({'messages': [{'role': 'user', 'content': content}],
                       'max_tokens': max_tokens, 'temperature': 0}).encode()
    req = urllib.request.Request(f'http://localhost:{port}/v1/chat/completions',
                                 data=body, headers={'Content-Type': 'application/json'})
    t0 = time.time()
    d = json.load(urllib.request.urlopen(req, timeout=1200))
    return time.time() - t0, d

CLASSES = {}

def code_run():
    lines = '\n'.join(f'  float w{i} = a[{i}] * b[{i}] + c[{i}];' for i in range(28))
    return ('Here is a C-like kernel snippet:\n\nfloat dot(float* a, float* b, float* c) {\n'
            + lines + '\n}\n\nContinue this file with a second function that computes the same dot '
            'product with fully unrolled loops and a header comment. Write production-quality C code.',
            'Finish the C function with clean idiomatic code, no explanation.')

def prose_run():
    return ('Write a detailed technical blog post explaining how GPU wavefront scheduling works, '
            'covering: wave64 vs wave32, occupancy, VGPR pressure, and memory coalescing. '
            'Be thorough and concrete, with examples.',
            'Continue the blog post with the next two paragraphs.')

def tool_run():
    return ('You are a coding agent. Given this repository state, emit a JSON tool call to patch the bug.\n\n'
            '```json\n{"files": {"src/sched.c": "line 42: for (int i=0; i<n; i++) { q[i] = p[i] * 2; }"}}\n```\n\n'
            'The bug: off-by-one when n == 0. Emit JSON with keys "file", "old", "new".',
            'Emit the corrected JSON tool call now.')

def mixed_run():
    return ('Review this patch and explain in a short paragraph what it does, then list any bugs:\n\n'
            '```c\nvoid gpu_flush(struct ctx *c, int ring) {\n  spin_lock(&c->lock);\n  if (ring < 0 || ring >= MAX_RINGS) return;\n'
            '  for (int i = 0; i <= c->ring[ring].count; i++)\n    write_reg(c, RING_DOORBELL + i, c->ring[ring].seq[i]);\n  spin_unlock(&c->lock);\n}\n```\n\n'
            'Then propose a corrected version as a diff.',
            'Provide the corrected diff in a code block, no further commentary.')

CLASSES['code'] = code_run
CLASSES['prose'] = prose_run
CLASSES['tool'] = tool_run
CLASSES['mixed'] = mixed_run

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=8093)
    ap.add_argument('--log', required=True)
    ap.add_argument('--label', default='run')
    ap.add_argument('--runs', type=int, default=3)
    ap.add_argument('--max-tokens', type=int, default=256)
    args = ap.parse_args()

    pos = log_path_size(args.log)
    results = {}
    for cls, fn in CLASSES.items():
        prompt, = [fn()[0]] if False else [None]
        decode_ts, accs, lens = [], [], []
        for r in range(args.runs):
            content = fn()[0] if r == 0 else fn()[0] + f'\n\n(Variation {r}: adjust wording and examples throughout.)'
            _, d = chat(args.port, content, args.max_tokens)
            new, _ = timing_lines(args.log, pos)
            pos = log_path_size(args.log)
            ev = [t for t in new if t[0] == 'eval']
            ac = [t for t in new if t[0] == 'accept']
            if ev:
                decode_ts.append(ev[-1][3])
            if ac:
                accs.append(ac[-1][1]); lens.append(ac[-1][2])
        results[cls] = {
            'decode': decode_ts,
            'acceptance': accs,
            'mean_len': lens,
        }
        m = statistics.mean(decode_ts) if decode_ts else 0
        a = statistics.mean(accs) if accs else 0
        print(f'{args.label} {cls:6s} decode {m:6.2f} tok/s  accept {a:.3f}  runs={decode_ts}')

    flat = [x for cls in results for x in results[cls]['decode']]
    print(f'{args.label} OVERALL mean {statistics.mean(flat):.2f} tok/s median {statistics.median(flat):.2f}')
    with open(f'/tmp/opencode/benchmix_{args.label}.json', 'w') as f:
        json.dump(results, f, indent=1)

if __name__ == '__main__':
    main()
