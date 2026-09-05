# RX 7900 XTX — Qwen3.8-27B serving benchmarks

Finding the fastest stable way to serve Qwen3.8-27B on a single RX 7900 XTX
(gfx1100, RDNA3) with the desktop sharing the GPU, primarily for coding/agentic
work (opencode).

**Agents: read RUNBOOK.md before running anything.** It has the hard limits
(~21.5 GiB VRAM because Hyprland lives on this card), the procedure, and the
work queue.

## The objective

Deliverables: **the engine + `llama-server`/hipfire launch parameters** that hit
all four targets at once.

| Target | Status |
|---|---|
| 100k context | **Met** — MTP + q4_0 KV fits on Vulkan (§5 V4, ~1.2 GB spare); safe variant V3 |
| Highest decode | **41.7 t/s at 81k**, 70.9 t/s mixed at 32k (Vulkan+MTP); hipfire DFlash2: 95 t/s mixed mean |
| Highest prefill / TTFT | 467.9 t/s (HIP turbo4, 81k); ~454 t/s (Vulkan+MTP, 81k) |
| Output quality | TurboQuant tiers below q4 excluded by owner rule; NIAH gate pending |

The intended use is a long-running agent harness (opencode) with prompt-cache
reuse; time-to-task-completion on real agentic work is the deciding metric, so
Phase 5 (WEB_BENCH.md) is the phase that matters.

## The current answer

Best 32k mixed-workload config (per `bench_mix`, 12 prompts):
**buun Vulkan + MTP `n-max 3`, q4_0 KV, Q4_K_M — 70.9 t/s mean.**
hipfire v0.3.0 beta (DFlash2, q8 KV, MQ4V2) beats it on the same corpus:
**95.1 t/s mean** — driven by tool-call/JSON turns (157 t/s) but loses prose.
Which one wins "usable" is what the web bench decides.

Full commands in RESULTS.md §6; every number in RESULTS.md §3–§5.

## Status

| Phase | State |
|---|---|
| 0 smoke · 1 engine baseline · 2 drafter | Done |
| 3 quant sweep | Q4_K_M done (+2.6% vs Q4_K_XL); Q3_K_XL pulled, pending |
| 4 backend/lever tests | Vulkan>HIP for MTP decode; amdvlk dropped; workload-bias quantified |
| 5 agentic web build | Tooling ready (WEB_BENCH.md) — this is the current phase |
| hipfire fair test | Micro-bench done (§5); web-bench pending |
| quality gate | Planned, nothing run |

## Documents

| File | What's in it |
|---|---|
| RESULTS.md | **All the data.** Engine inventory, KV tiers, server tables, localmaxxing cross-analysis, hipfair test |
| WEB_BENCH.md | Phase 5 procedure: port scheme, metrics, quality scoring |
| RUNBOOK.md | Start here for runs: procedure, safety, work queue |
| prompts/web-bench.md | The three one-shot stage prompts |
| scripts/ | `run-web-bench.sh`, `web_bench_metrics.py` (recording proxy), `gpu-monitor.sh` (rocm-smi), `bench_mix.py`/`bench_hf.py` (mixed-workload micro-bench) |
| results/web/ | Per-run JSONL + summaries; `results/web-bench.csv` aggregate |
| logs/ | Engine stderr, agent transcripts, VRAM telemetry per run |
| sites/ | The generated sites, one per run — quality evidence, reviewed by hand |

## Quick start

```sh
cd ~/Documents/7900xtx-inference-benchmarks
./scripts/run-web-bench.sh buun-vk ~/Documents/Qwen3.8-27B-UD-Q4_K_M.gguf p5-vk-q4km-mtp 0 \
  -md ~/Documents/mtp-Qwen3.8-27B-Q4_0.gguf --spec-type draft-mtp --spec-draft-n-max 3
```

Model loads take ~10-45 s (mmap); a hipfire cold start needs ~1 min and one
throwaway request (shader JIT).
