#!/usr/bin/env python3
"""bench_mix against a hipfire serve daemon (timings come from the API, not logs)."""
import json, statistics, sys, urllib.request
sys.path.insert(0, '/home/tom/Documents')
from bench_mix import CLASSES

def chat(port, content, max_tokens=256):
    body = json.dumps({'model': 'qwen3.8:27b',
                       'messages': [{'role': 'user', 'content': content}],
                       'max_tokens': max_tokens, 'temperature': 0}).encode()
    req = urllib.request.Request(f'http://localhost:{port}/v1/chat/completions',
                                 data=body, headers={'Content-Type': 'application/json'})
    return json.load(urllib.request.urlopen(req, timeout=1200))

def main():
    label = sys.argv[1] if len(sys.argv) > 1 else 'hipfire'
    results = {}
    for cls, fn in CLASSES.items():
        decode, dflash = [], []
        for r in range(3):
            content = fn()[0] + (f'\n\n(Variation {r}: adjust wording and examples throughout.)' if r else '')
            d = chat(11435, content)
            t = d['timings']
            decode.append(t['decode_tok_s'])
            dflash.append(t.get('dflash'))
        results[cls] = {'decode': decode, 'dflash': dflash}
        print(f'{label} {cls:6s} decode {statistics.mean(decode):7.2f} tok/s  dflash={dflash[0]}  runs={[round(x,1) for x in decode]}')
    flat = [x for c in results for x in results[c]['decode']]
    print(f'{label} OVERALL mean {statistics.mean(flat):.2f} median {statistics.median(flat):.2f}')
    json.dump(results, open(f'/tmp/opencode/benchmix_{label}.json', 'w'), indent=1)

if __name__ == '__main__':
    main()
