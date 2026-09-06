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

### 4.1 Site quality review log

Full diagnoses; never fix the artifact for the model — the shipped page is the
datum.

| Run | Verdict | Diagnosis |
|---|---|---|
| `p5-vk-q4km-mtp` (idx 0, dialed) | **FAIL — page unrenderable** | Model's one-shot HTML error. `index.html` (35 227 B) has 2 script opens vs 1 close: the `game.js` tag closes, but the inline script (line 527 → EOF — ticker loop, the IntersectionObserver adding `.in`, the live-generation demo) is never terminated → the browser drops the whole block unexecuted. CSS gates 36 `.reveal` elements at `opacity: 0` until JS adds `.in`, so hero, all 6 sections and the fishing canvas stay invisible. `game.js` parses clean (`node -e "new Function(...)"`). All content exists in source; only the reveal mechanism dies. Not a hosting or harness issue |
| `p5-vk-q4km` (idx 1, dialed) | **PASS** | 2/2 balanced script tags, reveal JS executes, renders fully |
| `p5-hipfire-q8` (idx 2) | **DNF — engine** | see §5: hipfire lacks OpenAI `tool_calls`; no site built |

## 5. Port registry

Update this table when a run claims an index. Never reuse one.

| Index | Site port | Label | Engine / model | Status |
|---|---|---|---|---|
| 0 | 4000 | `p5-vk-q4km-mtp` | buun-vk, Q4_K_M + MTP n3, q4_0 KV, 64k | **ok 1468 s (re-roll, dialed)** — S1 144/S2 1065/S3 247, peak VRAM 23.6 GiB; balanced HTML (2/2), identity grounded (9× Qwen), renders. First attempt (1282 s) wiped for broken site — 1282→1468 s across identical configs is the one-shot variance band |
| 1 | 4001 | `p5-vk-q4km` | buun-vk, Q4_K_M, q4_0 KV, 64k | **ok 1630 s (dialed)** — S1 177/S2 1018/S3 428, decode 31.6 avg, peak VRAM 17.2 GiB; HTML balanced (2/2 script tags) — renders |
| 2 | 4002 | `p5-mln-q4km-mtp` | **mainline** HIP (b10819), Q4_K_M + MTP n3, q4_0 KV, 64k | **ok 1131 s — LADDER LEADER** (S1 262/S2 601/S3 256), decode 49.7 avg, prefill 279.1, accept 72.3%, peak VRAM 21.2 GiB; HTML balanced, identity grounded (9× Qwen, 0× Pi-5); beats buun-vk MTP by 12% |
| 3 | 4003 | `p5-hipfire-q8` | hipfire DFlash2, q8 KV | **VOIDED — engine fail** (attempts used :4002 before mainline claimed it; no site built): hipfire v0.3.0 beta returns tool calls as plain text (no OpenAI `tool_calls`, `finish_reason: stop`) → pi issues 1 request/stage and exits; 29 s "garbage-success". Root cause: emit-layer extractor only knows Qwen3.5/3.6 format (RESULTS §6). Re-test when tools ship |
| _(none further)_ | | | | |

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
- **Sampling is dialed per the unsloth Qwen3.8-27B guide's instruct set** (temp 0.7, top_p 0.8, top_k 20, min_p 0, presence 1.5) — baked into `run-web-bench.sh` for llama engines and set as hipfire config overrides, so both engines sample identically. Do not run the ladder undialed (first attempt did: temp 0.8 defaults → voided).
- **MTP is on for all ladder runs from now on** (owner decision — no downside observed: acceptance holds at ctx, +21-31% wall-clock). Controls without MTP are optional extras, not defaults.
- Stage 1 states the model's real identity (Qwen3.8-27B, `{{QUANT}}`) — the pre-amendment prompt let the agent confabulate a persona out of the label mnemonic (`p5` → "Raspberry Pi 5").
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
