# AMD RX 7900 XTX — Qwen3.8-27B inference report

Single-machine analogue of [p100-inference-benchmarks](https://github.com/Tom1tk/p100-inference-benchmarks), condensed to one file.
Objective: the highest decode, the highest prefill, and 100k context (q4-class KV) on one 24 GB card,
producing `llama-server` launch parameters to serve the model from another program (e.g. opencode).

*Generated 2026-09-05. All numbers measured locally unless marked otherwise.*

---

## 1. Hardware & stack

| Item | Value |
|---|---|
| GPU | AMD Radeon RX 7900 XTX (Navi 31, gfx1100, RDNA3), 24 GB VRAM |
| CPU / RAM | Ryzen 7 5800X3D (8C/16T) · 32 GB |
| OS | CachyOS Linux (Arch), kernel `amdgpu` + `/dev/kfd`, **GUI (Hyprland) shares this GPU** |
| ROCm | **7.2.4-1** (pacman `rocm-hip-sdk`), amdclang 22.0 |
| Vulkan | RADV (mesa 26.2.2) — `vulkan-radeon`; official AMD ICD (amdvlk) **not** tested yet |
| Builds | HIP: `-DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1100` + amdclang · Vulkan: `-DGGML_VULKAN=ON` (both `-DLLAMA_BUILD_SERVER=ON`, Release) |
| GPU shares desktop | Effective VRAM budget ≈ **21.5 GB**, not 24.5 GB |

## 2. Engines & models

| Engine | Repo | Verdict for this model |
|---|---|---|
| `Tom1tk/mtp-pflash-turboquant-hip` (mtp fork) | `~/Documents/mtp-pflash-turboquant-hip` | **Cannot load the model** — lacks `ssm_conv1d`/hybrid arch support. MTP tensors "preserved but unused". **Outdated; parked.** |
| `ggml-org/llama.cpp` (mainline) | `~/Documents/llama.cpp` | Works. No turboquant / MTP-drafter features. Baseline only. |
| `spiritbuun/buun-llama-cpp` (buun) | `~/Documents/buun-llama-cpp` | **Primary engine.** HIP build (`build/`) + Vulkan build (`build-vk/`). Turbo KV tiers are HIP-only; MTP works on both. |
| tinygrad | `~/Documents/tinygrad` | RDNA3 Qwen3.8 27B kernels, 46 t/s claimed, no spec decode. Untested here (OOM'd 21.6/21.5 GB, hung GPU). Retry from TTY with `qwen3.8:27b` preset. |

Models (in `~/Documents/`): `Qwen3.8-27B-UD-Q4_K_M.gguf` (**default target, 16 GiB**) + `Qwen3.8-27B-UD-Q4_K_XL.gguf` (16.34 GiB) + `Qwen3.8-27B-UD-Q3_K_XL.gguf` (pulled, untested) + `mtp-Qwen3.8-27B-Q4_0.gguf` (MTP drafter, 18 tensors, 1.3 GB — only usable via `--spec-type draft-mtp`).

**External anchor:** [localmaxxing record](https://www.localmaxxing.com/en/runs/cmt00amga0eeums015vw8ttp3) — same GPU + same model file (Unsloth UD-Q4_K_XL): 90.74 t/s code / 64.99 prose decode, llama.cpp **Vulkan** (Windows, official AMD ICD), MTP `n-max 3`, q4_0 KV; claims ~88 code t/s at 100k daily serve. Also [hipfire run](https://www.localmaxxing.com/en/runs/cmsnp1w7300jqo001njoxttpa-family): 154 t/s with a Qwen3.6 DFlash draft (`--kv-mode asym3`), 58.8% accept.

## 3. KV cache tiers — decode & short-context prefill (HIP, `llama-bench`, -r 3, 4096 ctx)

| KV type | pp512 t/s | tg128 t/s |
|---|---:|---:|
| f16 | 806.9 | **33.61** |
| q8_0 | 799.7 | 32.86 |
| **turbo4** | 794.7 | **33.00** ← best q4-class |
| turbo2 | 795.3 | 32.45 |
| turbo2_tcq | 776.7 | 32.45 |
| q4_0 | 790.8 | 32.64 |

**Owner rule: KV never above q4 → `turbo4` on HIP, `q4_0` on Vulkan** (turbo tiers don't run on Vulkan; see §5).

## 4. Prefill lever — ubatch (HIP, pp4096, turbo4/turbo4)

| -b | -ub | pp4096 t/s |
|---:|---:|---:|
| 2048 | 512 | 764.0 |
| 4096 | 512 | 758.6 |
| **2048** | **2048** | **800.5** |
| 4096 | 2048 | 797.4 |
| 4096 | 4096 | 797.2 |

**`-b 2048 -ub 2048`** — +4.5%; 4096 adds nothing.

## 5. Server measurements

`llama-server`, `-fa on -t 8 -b 2048 -ub 2048`, chat completions over HTTP. VRAM = whole-card usage incl. desktop (~0.9 GB).

### HIP (build/)
| # | Config | Context | Prefill | Decode | Accept | VRAM |
|---|---|---|---:|---:|---:|---|
| S1 | no drafter, f16 KV | 4k | 175 t/s | 33.6 t/s | — | 17.8 GB |
| S2 | + MTP drafter, f16 KV | 4k | 177.6 t/s | 39.4 t/s | 44.0% (2.10 mean len) | 19.4 GB |
| S3 | turbo4 KV, no drafter | **81k** | **467.9 t/s** | 19.0 t/s | — | 21.3 GB (~3.2 GB headroom) |
| S4 | + MTP + turbo4, -ub 1024 | 100k | — | — | — | loads at 23.8 GB; **request OOM** (needs +2 GB compute) |
| S5 | + MTP + turbo2, -ub 1024 | 100k | ~486 t/s to 71% | — | — | **hard OOM crash at 57k tokens prefill** |

### Vulkan / RADV (build-vk/)
| # | Config | Context | Prefill | Decode | Accept | VRAM |
|---|---|---|---:|---:|---:|---|
| V1 | plain, q4_0 KV (`llama-bench`) | 4k | 738.1 t/s | 31.3 t/s | — | — |
| V2 | + MTP `n-max 3`, draft KV q4_0 | 32k | 329.9 t/s | **65.9 t/s** | **70.3%** (2.46 mean len) | 24.8 GB (~1 GB free) |
| V3 | no drafter, q4_0 KV | 81k | 430.1 t/s | 26.5 t/s | — | 20.0 GB (~4.6 GB headroom) |
| V4 | **+ MTP `n-max 3`, draft KV q4_0** | **81k** | **453.8 t/s** | **41.7 t/s** | **60.0%** (2.76 mean len) | **24.5 GB (~1.2 GB free)** |

Backend notes:
- buun's `turbo*` KV tiers **abort on Vulkan** (`SET_ROWS` op not implemented). Vulkan → `q4_0` KV; turbo tiers are HIP-only.
- MTP acceptance holds at long context: 60% at 81k (≈ P100 rig's 60.3%), 70.3% at 32k.
- **MTP + 100k fits on Vulkan** (~1.2 GB spare) but is close to the GUI-crash line; V3 is the safe variant.
- On HIP, MTP + 100k does not fit with the 17 GB model + GUI (S4/S5).

### Mixed-workload decode (V2 config, 32k ctx, `~/Documents/bench_mix.py`, n=3 per class, temp 0)

| class | Q4_K_XL decode | Q4_K_XL accept | Q4_K_M decode | Q4_K_M accept |
|---|---:|---:|---:|---:|
| code | 65.85 | 64.0% | **69.52** | **70.0%** |
| prose | 65.04 | 62.9% | **69.56** | **70.6%** |
| tool-call/JSON | 75.04 | 81.2% | 74.72 | 80.3% |
| mixed (agentic) | 70.25 | 73.5% | 69.89 | 72.0% |
| **overall** | 69.1 mean / 68.6 med | | **70.9 mean / 70.6 med** | |

**Q4_K_M verdict: ~+2.6% decode and better code/prose acceptance (70% vs 64%) at 16 GiB vs 16.34 GiB.** Tool-call class unchanged (~75). Q4_K_M is now the default target weights. (`Qwen3.8-27B-UD-Q3_K_XL.gguf` pulled — next in ladder.)

**Usable opencode expectation at 32k: ~70-75 t/s.** No code/prose gap on these prompts; JSON-dense tool turns are where MTP acceptance peaks (~80%).

### hipfire v0.3.0 beta — fair test done (2026-09-05 evening)

Install: `~/.hipfire` (beta, commit 7b16762, rustup-built, gfx1100). Model: `hipfire pull qwen3.8:27b` (MQ4V2, 15.66 GB) + `qwen38-27b-dflash-mq4.hfq` (1.21 GB draft).

Setup friction (beta bugs, both worked around):
- Registry cache (`~/.hipfire/registry.cache.json`) omits the `dflash` sidecar for `qwen3.8:27b`/`-mq4-pro`/`-mq4-xt` despite their own code comments declaring it → **patched the cache JSON locally** to point at the draft sidecar.
- `developer.dflash_draft` config key is not consulted by the serve pre-warm path.

Serve config: `hipfire serve qwen3.8:27b --kv-mode q8 --idle-timeout 0 -d`, `thinking off`, speculation=dflash/on. 22.7 GB VRAM total (incl. desktop), 262k max_seq, 16/64 layers carry KV.

**Same bench_mix corpus, n=3, temp 0, 256 tok (vs ours: Vulkan+MTP n-max 3, q4_0 KV, Q4_K_M, 32k ctx):**

| class | hipfire DFlash2 decode | ours (Vulkan+MTP) |
|---|---:|---:|
| code | 81.4 (54.6-95.7 spread!) | 69.5 |
| prose | 57.8 | 69.6 |
| tool-call/JSON | **156.9** (136.8-178.2) | 74.7 |
| mixed (agentic) | 84.0 | 69.9 |
| **overall** | **95.1 mean / 86.3 median** | 70.9 mean / 70.6 med |

Verdict: hipfire wins the corpus overall (+34%), overwhelmingly on JSON-dense tool turns (+110%); we win prose (+20%). Caveats before switching:
- **q8 KV** on their side vs our q4_0 — not quality-equal; and MQ4V2 is their custom quant (claimed KLD 0.039 vs teacher, unverified here).
- High within-class variance (code 54.6→95.7) — verify with more runs before trusting the code number.
- Prefill ~250-330 t/s (comparable), cold-start TTFT is bad (~11 s first request, shader JIT).
- Serving maturity for opencode (tool-call formats, streaming, jinja) is behind llama.cpp.
- DFlash2 draft acceptance data not surfaced per-request in this build (`tau` 10.38 on the smoke test).

### Localmaxxing cross-analysis (workload-selection bias, not luck)

Run-to-run variance across independent testers is tiny (our code 65.9 vs record's prose 64.99 — different people, OSes, within 1.5%). The spread is **prompt-dependent acceptance**: code-heavy prompts (~70%+) inflate the headline; the 90.74 record is a code-max, its own prose is 64.99. A `tokSOut` leaderboard with free-text prompts structurally rewards this (27-token vs 512-token prompt runs aren't comparable). Benchmark every config on a fixed mixed corpus before believing a number.

Counter-example of an honest submission: `cmtm2ld5e00wsoe01orhwjj4z` (SolusBolus, HIP ROCm 7.14 custom build, mainline llama.cpp b10791 — **MTP is now merged upstream**): 58 t/s, 128k ctx, q8_0 KV, `--spec-draft-p-min 0.8` (confidence-gated drafting), full serving config (metrics, mmproj, vision). That is a real daily-driver number, not a bench rig.

### amdvlk — investigated, dropped

AMDVLK went into maintenance in 2025; AMD steers to RADV (Mesa), which is what we use. The record's "official AMD Vulkan ICD" is the **Windows** proprietary driver path — no maintained Linux equivalent. Our prose decode already matches the record's prose (65.87 vs 64.99): the gap is workload, not driver. No further action.

### hipfire (https://github.com/warpfront/hipfire) — candidate for fair test

Status since ~2026-03: v0.2.1 stable / **v0.3.0 beta adds Qwen 3.8 27B** (`qwen3.8:27b` MQ4V2 ladder + drafts), 5k commits, Rust+HIP RDNA3-tuned kernels, "Redline" kernel-graph replay (launch-overhead elimination, fail-closed), OpenAI-compatible daemon on :11435.

| | code | prose | tool | mixed | KV | prefill | ctx |
|---|---:|---:|---:|---:|---|---:|---|
| ours (Vulkan+MTP n-max 3, bench_mix) | 69.5 | 69.6 | 74.7 | 69.9 | q4_0 | 330 | 32k |
| **hipfire v0.3.0 beta (DFlash2, q8 KV, MQ4V2)** | 81.4 | 57.8 | **156.9** | 84.0 | q8 | 250-330 | 262k cap |
| hipfire 154-run config (localmaxxing) | ~154 | 37.5 | ? | ? | **asym3 (3-bit!)** | 51 | 2k |

Read the fine print: the 154 headline is code-genre with a Qwen**3.6** cross-genre DFlash draft; native 3.8 DFlash2 = 81.7 code / 45.8 prose; prose with 3.6 draft = 37.5. Their current DFlash claims use q8 KV; the headline run used a 3-bit KV and a 27-token prompt. **The beta fair test (above) is now the authoritative hipfire row.**

Costs to adopt: their MQ4V2 SKU (5.18 bpw, slightly larger than Q4_K_XL), less battle-tested serving for opencode (jinja/tool-calling/streaming). **Fair test complete — see §5 "hipfire v0.3.0 beta".** Remaining questions: quality parity (MQ4V2 + their draft math) via NIAH-style gate, variance re-run (code class spread 54-96 t/s), and opencode end-to-end.

## 6. Recommended serve commands (deliverable)

### A. 100k context — max decode (Vulkan + MTP) — measured 453.8/41.7 t/s
```sh
GGML_VK_ALLOW_GRAPHICS_QUEUE=1 ~/Documents/buun-llama-cpp/build-vk/bin/llama-server \
  -m ~/Documents/Qwen3.8-27B-UD-Q4_K_XL.gguf \
  -md ~/Documents/mtp-Qwen3.8-27B-Q4_0.gguf \
  --device Vulkan0 -ngl 999 -ngld 999 \
  --spec-type draft-mtp --spec-draft-n-max 3 \
  --spec-draft-type-k q4_0 --spec-draft-type-v q4_0 \
  -fa on -t 8 -b 2048 -ub 2048 \
  -c 100000 -ctk q4_0 -ctv q4_0 \
  --parallel 1 --no-mmproj --jinja --reasoning-budget 0 --port 8080
```
⚠️ ~1.2 GB spare with GUI running. Safe fallback = same command without `-md`/`--spec-*` (V3: 430/26.5 t/s, 4.6 GB spare).

### B. Highest decode — 32k context (Vulkan + MTP) — measured 65.9 t/s, 70.3% accept
```sh
GGML_VK_ALLOW_GRAPHICS_QUEUE=1 ~/Documents/buun-llama-cpp/build-vk/bin/llama-server \
  -m ~/Documents/Qwen3.8-27B-UD-Q4_K_XL.gguf \
  -md ~/Documents/mtp-Qwen3.8-27B-Q4_0.gguf \
  --device Vulkan0 -ngl 999 -ngld 999 \
  --spec-type draft-mtp --spec-draft-n-max 3 \
  --spec-draft-type-k q4_0 --spec-draft-type-v q4_0 \
  -fa on -t 8 -b 2048 -ub 2048 \
  -c 32768 -ctk q4_0 -ctv q4_0 \
  --parallel 1 --no-mmproj --jinja --reasoning-budget 0 --port 8080
```

### C. Highest prefill — HIP turbo4 at 100k (467.9 t/s prefill, 19.0 t/s decode, 3.2 GB headroom)
```sh
~/Documents/buun-llama-cpp/build/bin/llama-server \
  -m ~/Documents/Qwen3.8-27B-UD-Q4_K_XL.gguf \
  -ngl 99 -fa on -t 8 -b 2048 -ub 2048 \
  -ctk turbo4 -ctv turbo4 -c 100000 \
  --jinja --reasoning-budget 0 --port 8080
```
(`--reasoning-budget 0` disables thinking — without it, reasoning models burn output budget on hidden thinking tokens. Keep it unless thinking is wanted.)

## 7. Caveats

- **GUI on the same GPU.** Keep total VRAM ≤ ~21.5 GB comfortable; V4 at 24.5 GB is workable but a browser-heavy desktop can push it over. A hard GPU reset recovers the card but kills the session (happened once, S5).
- **tinygrad OOM'd and hung the GPU.** Never run its 27B example with the GUI up; prefer TTY/SSH.
- **turbo2/turbo2_tcq are below q4** — quality tradeoff, untested (P100 rig rule: any lossy win needs a NIAH gate first).
- Qwen 3.8 is a reasoning model: empty answers with small `max_tokens` = thinking tokens consumed, not errors.
- The record's "17.48 GiB dedicated VRAM" on Windows ≠ our whole-card accounting; same stack here uses ~23.9 GB for the same 32k MTP config.

## 8. Open levers (next experiments)

1. **Q3_K_XL weights** (pulled, next in ladder) — same bench_mix ladder; if decode holds, frees ~2 GB for MTP+100k headroom.
2. **hipfire follow-ups**: variance re-run on code class; quality gate (NIAH) hipfire vs ours; opencode end-to-end against the daemon (tool calls, streaming).
3. **MTP acceptance/param tuning**: `--spec-draft-n-max` sweep (2/3/4/5), `--spec-draft-p-min` (SolusBolus uses 0.8); V2 hit 70.3% with n-max 3.
4. **MTP context ceiling** between 32k and 100k for the largest context keeping ≥2 GB headroom (Vulkan).
5. **VBR dynamic KV** (`--vbr-entry/--vbr-floor/--vbr-vram`, HIP only) — may make 100k+MTP fit with more headroom.
6. **tinygrad RDNA3 kernels** (46 t/s claimed) from a TTY session with the IQ4_XS preset.
7. Quality gate (NIAH) before trusting q4_0/turbo4 long-context answers — not yet run.
8. ~~amdvlk~~ — dropped (deprecated; RADV matches the record's prose decode; gap is workload, not driver).
9. ~~hipfire install + fair test~~ — done, §5 (upstream registry bug patched locally; report upstream).
