# Phase 5 — agentic web-build benchmark

The final phase. Everything before it measures the engine in isolation
(`llama-bench`, `bench_mix`); this measures whether a model version is actually
**usable** for real one-shot agentic work.

Throughput benchmarks report t/s on synthetic fixed prompts. They cannot tell
you whether a config completes a multi-step task, how it behaves once the
context fills with tool output, whether speculative decoding still helps when
the workload is code and JSON rather than prose, or — the question that motivated
porting this phase to the 7900 XTX — **how long the whole task takes end to end**
(prefill + decode + tool execution). That last number is what decides between
engines whose t/s numbers cross in different places: a fast-decode/slow-prefill
engine and a slow-decode/fast-prefill engine can tie on t/s and lose by minutes
on wall clock.

## 1. What it does

For each model version, `scripts/run-web-bench.sh`:

1. Starts the engine for that run:
   - `buun-vk` — buun `build-vk/bin/llama-server` (Vulkan/RADV), any GGUF + optional MTP drafter
   - `buun-hip` — buun `build/bin/llama-server` (HIP/ROCm), turbo-KV tiers available
   - `hipfire` — `hipfire serve` daemon (MQ quants, DFlash2)
   with tool-call support (`--jinja` on llama.cpp; hipfire handles its own templates).
2. Starts a recording proxy between the agent and the engine.
3. Runs `pi` through the three prompts in `prompts/web-bench.md`, one continuous
   session, in `sites/<label>/`.
4. Tears down, summarizes, commits, and pushes.

The prompts build an Express site about the model itself: a working page served
as a background process (stage 1), an elaborate restyle with a JS interactive
element (stage 2), and a canvas mini-game in a separate static file (stage 3).
They are written to be completed **one-shot** — a model that stops to ask the
operator a question has failed the stage, and that is a result worth recording.

Stage 3 in particular is the stress test the earlier phases can't provide: a
model that produces plausible-looking but broken game logic, or that mangles the
tool calls needed to write `public/game.js`, will look perfectly healthy in a
t/s number.

## 2. Running one

```bash
cd ~/Documents/7900xtx-inference-benchmarks
./scripts/run-web-bench.sh <engine> <model-spec> <label> <index> [extra engine args...]
```

```bash
# Vulkan + MTP on Q4_K_M (the current best 32k config)
./scripts/run-web-bench.sh buun-vk ~/Documents/Qwen3.8-27B-UD-Q4_K_M.gguf p5-vk-q4km-mtp 0 \
  -md ~/Documents/mtp-Qwen3.8-27B-Q4_0.gguf --spec-type draft-mtp --spec-draft-n-max 3 \
  --spec-draft-type-k q4_0 --spec-draft-type-v q4_0

# same weights, no drafter control
./scripts/run-web-bench.sh buun-vk ~/Documents/Qwen3.8-27B-UD-Q4_K_M.gguf p5-vk-q4km 1

# HIP + turbo4 KV
./scripts/run-web-bench.sh buun-hip ~/Documents/Qwen3.8-27B-UD-Q4_K_M.gguf p5-hip-q4km-tq4 2 \
  -ctk turbo4 -ctv turbo4

# hipfire (model-spec = registry tag; q8 KV is their methodology default)
./scripts/run-web-bench.sh hipfire qwen3.8:27b p5-hipfire-q8 3
```

`<index>` must be unique per model version and is the whole port scheme:

| Resource | Port | Example (index 3) |
|---|---|---|
| Website | `4000 + index` | 4003 |
| Engine | `8100 + index` | 8103 |
| Metrics proxy | `8200 + index` | 8203 |

**Sites are left running on purpose.** Each run creates `<label>.service`, so
after the phase every model's site is browsable side by side at 4000, 4001,
4002… The script refuses to start if any of its three ports is already bound,
which is what catches a reused index.

Keep the registry in §5 current so indices don't get reused.

## 3. What gets measured

Per request, captured by the proxy from the engine's `timings` object
(llama.cpp: `prompt_n`/`prompt_per_second`/`predicted_n`/`predicted_per_second`;
hipfire: `prefill_ms`/`prefill_tok_s`/`decode_tok_s` + usage counts — the proxy
normalizes both into the same record).

Aggregated per stage and for the whole task:

- **Total task time** — wall clock, all three stages, including tool execution
  and `npm install`. This is the number that answers "is this usable?" and the
  headline for engine-vs-engine decisions on this rig.
- **Total tokens generated** — sum of `predicted_n`.
- **Prefill t/s** — avg / min / max across requests.
- **Decode t/s** — avg / min / max across requests.

Avg/min/max matter more than the mean alone: decode t/s degrades as the agent's
context fills, so a wide min–max spread means the model slows down exactly when
the task gets hard. A tg128 number never shows this.

Outputs:

| Path | Content |
|---|---|
| `results/web/<label>.jsonl` | one record per request — the raw evidence |
| `results/web/<label>.json` | per-stage and overall summary |
| `results/web-bench.csv` | one row per run, machine-readable aggregate |
| `sites/<label>/` | the generated site — quality evidence, reviewed by hand |
| `logs/<label>.server.log` | engine stderr, including acceptance-rate lines |
| `logs/<label>.agent.log` | full agent transcript |
| `logs/<label>.vram.log` | VRAM + clock telemetry (rocm-smi) |

### Why a proxy and not the engine log

Both engines emit timing data in their OpenAI-compatible responses (llama.cpp in
the `timings` object; hipfire in `timings` + `hipfire.tok_s`), but their **log**
formats differ. The proxy is the one collector that works unchanged across both,
and it gives per-request granularity. It relays SSE chunks as they arrive rather
than buffering, so it does not distort the latency it is measuring.

## 4. Scoring quality

Throughput is only half the point. After each run, open the site and record in
RESULTS.md:

| Check | Pass condition |
|---|---|
| Stage 1 | Site responds on its port from a background process |
| Stage 2 | Restyle applied; the JS interactive element actually works |
| Stage 3 | Game present, `public/game.js` loaded via `<script src>`, hook falls/reels on hold-release, fish are catchable, score increments |
| One-shot | Did the model complete each stage without asking a question? |
| Tool calls | Any malformed tool calls in `logs/<label>.agent.log`? |

Record the failure mode, not just pass/fail — "produced a game that never
increments the score" and "mangled every `write` call" are very different
verdicts about a config.

## 5. Port registry

Update this table when a run claims an index. Never reuse one.

| Index | Site port | Label | Engine / model | Status |
|---|---|---|---|---|
| _(none yet)_ | | | | |

## 6. Prerequisites

- `pi` on PATH (`@earendil-works/pi-coding-agent`; v0.85.1 here, P100 used v0.78.0).
- **`PI_OFFLINE=1` is required** — the script sets it. Without it `pi` blocks on
  startup network operations (verified on the P100 rig; re-verify if this box
  behaves differently).
- Node.js and `npm` available to the agent. No sudo/systemd needed — this rig is
  an interactive desktop, not a server container; sites run as ordinary
  background processes and stay up after the run.
- The agent's `pi` config is written per-run into `sites/<label>/.pi-agent/`.
  The operator's own pi config is never touched.
- hipfire runs need `~/.hipfire/bin` on PATH and the registry sidecar patch from
  RESULTS.md §5 (upstream bug at time of writing).

### Tunables

| Env var | Default | When to change |
|---|---|---|
| `CTX` | `32768` | Agentic transcripts fill context fast; don't go lower without noting it |
| `STAGE_TIMEOUT` | `3600` | Raise for slow configs. Exit code 124 from a stage means this was hit |
| `LOAD_TIMEOUT` | `600` | Raise under heavy disk contention |
| `VRAM_LIMIT_MIB` | `22000` | Preflight aborts if idle usage + model leaves less than this headroom margin; also the live guard line for the GUI |

A stage that hits `STAGE_TIMEOUT` is recorded as `FAILED(stageN)` and still
committed. **That is a legitimate result** — "could not finish the task in an
hour" is exactly the usability signal this phase exists to capture.
