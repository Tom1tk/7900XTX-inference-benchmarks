# RESULTS — RX 7900 XTX, Qwen3.8-27B

All measured data. Companion docs: METHODOLOGY-style facts are inlined in §1;
procedure in RUNBOOK.md; web-bench (phase 5) results will land in `results/web/`.

*Measured 2026-09-05 on CachyOS, ROCm 7.2.4 / RADV Mesa 26.2.2. VRAM figures are whole-card (desktop included, ~0.9 GB idle).*

## 1. Setup

| Item | Value |
|---|---|
| GPU | AMD RX 7900 XTX (gfx1100, RDNA3), 24 GB VRAM — **desktop (Hyprland) shares it: effective budget ≈ 21.5 GiB** |
| CPU / RAM | Ryzen 7 5800X3D (8C/16T) · 32 GB |
| ROCm / Vulkan | ROCm 7.2.4-1 (amdclang 22.0) · RADV (vulkan-radeon) — amdvlk investigated, dropped (deprecated) |
| Engines | `buun-llama-cpp` HIP build (`build/`) + Vulkan build (`build-vk/`); `hipfire` v0.3.0 beta (`~/.hipfire`, commit 7b16762); tinygrad cloned, untested |
| Excluded engines | `Tom1tk/mtp-pflash-turboquant-hip` (cannot load this arch — lacks `ssm_conv1d`, MTP unused), mainline llama.cpp ~~(no MTP at our build)~~ — **no longer excluded**: checkout now at b10819 (post-merge), HIP binary supports `--spec-type draft-mtp` / `draft-dflash` / `draft-dspark`; joins the ladder as idx 2+ |

Models in `~/Documents/`:

| File | Role | Size |
|---|---|---|
| `Qwen3.8-27B-UD-Q4_K_M.gguf` | **default target weights** (866-tensor hybrid arch) | 16 GiB |
| `Qwen3.8-27B-UD-Q4_K_XL.gguf` | first-run weights | 16.34 GiB |
| `Qwen3.8-27B-UD-Q3_K_XL.gguf` | pulled, untested | — |
| `mtp-Qwen3.8-27B-Q4_0.gguf` | MTP drafter module (18 tensors; only via `--spec-type draft-mtp`) | 1.3 GiB |
| `~/.hipfire/models/qwen3.8-27b.mq4` + `qwen38-27b-dflash-mq4.hfq` | hipfire MQ4V2 + DFlash2 draft | 15.7 + 1.2 GiB |

Owner rules: **KV cache never above q4**; sub-q4 tiers need a quality gate before use; thinking disabled (`--reasoning-budget 0`) for serving.

## 2. Table A — `llama-bench` micro-bench (isolated engine)

Weights fully offloaded, `-t 8 -r 3`, 4096 ctx, Q4_K_XL.

### KV tier sweep (HIP)

| KV type | pp512 t/s | tg128 t/s |
|---|---:|---:|
| f16 | 806.9 | **33.61** |
| q8_0 | 799.7 | 32.86 |
| **turbo4** | 794.7 | **33.00** ← best q4-class |
| turbo2 | 795.3 | 32.45 |
| turbo2_tcq | 776.7 | 32.45 |
| q4_0 | 790.8 | 32.64 |

Verdict: **turbo4 on HIP, q4_0 on Vulkan** (turbo tiers abort on Vulkan — `SET_ROWS` op unimplemented in ggml-vulkan).

### Prefill lever (HIP, pp4096, turbo4)

| -b | -ub | pp4096 t/s |
|---:|---:|---:|
| 2048 | 512 | 764.0 |
| 4096 | 512 | 758.6 |
| **2048** | **2048** | **800.5** |
| 4096 | 2048 | 797.4 |
| 4096 | 4096 | 797.2 |

Verdict: **`-b 2048 -ub 2048`** everywhere.

### Backends, plain

| backend | pp512 | tg128 |
|---|---:|---:|
| HIP | 795 | 33.0-33.6 |
| Vulkan/RADV | 738.1 | 31.3 |

Verdict: plain HIP is slightly faster; **Vulkan wins once MTP is on** (Table B).

### Quant sweep (Vulkan, mixed-workload `bench_mix`, 12 prompts)

| quant | code | prose | tool | mixed | overall |
|---|---:|---:|---:|---:|---:|
| Q4_K_XL | 65.85 | 65.04 | 75.04 | 70.25 | 69.1 mean / 68.6 med |
| **Q4_K_M** | **69.52** | **69.56** | 74.72 | 69.89 | **70.9 mean / 70.6 med** |

Verdict: **Q4_K_M default** (+2.6% decode, better code/prose acceptance 70% vs 64%, 0.3 GiB smaller). Q3_K_XL queued.

## 3. Table B — `llama-server` / hipfire runs (HTTP, `-fa on -t 8 -b 2048 -ub 2048`)

### HIP (build/)

| # | Config | Context | Prefill | Decode | Accept | VRAM |
|---|---|---|---:|---:|---:|---|
| S1 | no drafter, f16 KV | 4k | 175 t/s | 33.6 t/s | — | 17.8 GB |
| S2 | + MTP, f16 KV | 4k | 177.6 t/s | 39.4 t/s | 44.0% (2.10 mean len) | 19.4 GB |
| S3 | turbo4 KV | 81k | **467.9 t/s** | 19.0 t/s | — | 21.3 GB (3.2 GB spare) |
| S4 | + MTP + turbo4, ub 1024 | 100k | — | — | — | loads at 23.8 GB, **request OOM** (+2 GB compute needed) |
| S5 | + MTP + turbo2, ub 1024 | 100k | ~486 t/s to 71% | — | — | **hard OOM crash at 57k prefill** |

### Vulkan / RADV (build-vk/)

| # | Config | Context | Prefill | Decode | Accept | VRAM |
|---|---|---|---:|---:|---:|---|
| V1 | plain, q4_0 KV (`llama-bench`) | 4k | 738.1 t/s | 31.3 t/s | — | — |
| V2 | + MTP n-max 3, draft KV q4_0 | 32k | 329.9 t/s | 65.9 t/s | 70.3% (2.46) | 24.8 GB (~1 GB free) |
| V3 | no drafter, q4_0 KV | 81k | 430.1 t/s | 26.5 t/s | — | 20.0 GB (4.6 GB spare) |
| V4 | **+ MTP n-max 3, draft KV q4_0** | **81k** | **453.8 t/s** | **41.7 t/s** | **60.0%** (2.76) | 24.5 GB (~1.2 GB free) |

Key findings: **MTP+100k fits on Vulkan, not on HIP.** MTP acceptance holds at long context (60% at 81k ≈ P100 rig's 60.3%). V4 runs live but leaves ~1.2 GB — near the desktop-crash line; V3 is the safe variant.

### hipfire v0.3.0 beta (DFlash2, q8 KV, MQ4V2, 262k cap)

| class | hipfire decode | ours (Vulkan+MTP Q4_K_M) |
|---|---:|---:|
| code | 81.4 (54.6-95.7 spread) | 69.5 |
| prose | 57.8 | 69.6 |
| tool-call/JSON | **156.9** (136.8-178.2) | 74.7 |
| mixed | 84.0 | 69.9 |
| **overall** | **95.1 mean / 86.3 median** | 70.9 mean / 70.6 med |

Prefill 250-330 t/s; cold-start TTFT ~11 s (shader JIT); 22.7 GB VRAM. hipfire wins tool/JSON-heavy turns (+110%), loses prose (-17%). Caveats: q8 KV (not quality-equal), unverified MQ4V2 quant (claimed KLD 0.039), high code-class variance — re-run before trusting.

### Recommended serve commands

Sampling: **dialed per the [unsloth Qwen3.8-27B guide](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) instruct (non-thinking) set — `--temp 0.7 --top-p 0.8 --top-k 20 --min-p 0.0 --presence-penalty 1.5`** (repeat-penalty stays 1.0). llama.cpp defaults (0.8/0.95/40/0.05) are hotter than either recommended set; thinking mode wants temp 1.0/0.95. **All numbers above §2-§3 were measured at llama.cpp default sampling (temp 0.8) — treat relative rankings as valid, absolute values as @0.8.** hipfire's built-in was temp 0.3/top_p 0.8/top_k 20 (its own dial) — the fair test ran there; re-dialed to the Qwen instruct set (0.7/0.8/20/pres 1.5/rp 1.0) for the web-bench ladder so engines sample identically.

**A. 100k max decode (Vulkan+MTP; ~1.2 GB spare):**
```sh
GGML_VK_ALLOW_GRAPHICS_QUEUE=1 ~/Documents/buun-llama-cpp/build-vk/bin/llama-server \
  -m ~/Documents/Qwen3.8-27B-UD-Q4_K_M.gguf -md ~/Documents/mtp-Qwen3.8-27B-Q4_0.gguf \
  --device Vulkan0 -ngl 999 -ngld 999 --spec-type draft-mtp --spec-draft-n-max 3 \
  --spec-draft-type-k q4_0 --spec-draft-type-v q4_0 \
  -fa on -t 8 -b 2048 -ub 2048 -c 100000 -ctk q4_0 -ctv q4_0 \
  --temp 0.7 --top-p 0.8 --top-k 20 --min-p 0.0 --presence-penalty 1.5 \
  --parallel 1 --no-mmproj --jinja --reasoning-budget 0 --port 8080
```

**B. 32k max decode — same as A with `-c 32768`.**

**C. Safe 100k (no drafter, 4.6 GB spare):** command A minus `-md`/`--spec-*`.

**D. Highest prefill (HIP turbo4, 81k):** `build/bin/llama-server -ctk turbo4 -ctv turbo4 -c 100000` + same shared flags; 467.9/19.0 t/s.

## 4. External cross-analysis

### Localmaxxing (workload-selection bias, not luck)

The [record run](https://www.localmaxxing.com/en/runs/cmt00amga0eeums015vw8ttp3) (90.74 t/s, same GPU+model, Windows Vulkan) decomposes as: 90.74 **code** / 64.99 prose / 77.81 mixed — our prose (65.9) matches their prose within 1.5% across different OSes and people. Run-to-run variance is tiny; headline spread is prompt-dependent MTP acceptance (code ~70%+, JSON ~80%, reasoning-heavy prose lower). A `tokSOut` leaderboard with free-text prompts structurally rewards prompt selection. Benchmark on a fixed mixed corpus before believing a number.

Honest submission counter-example: `cmtm2ld5e00wsoe01orhwjj4z` (SolusBolus, HIP ROCm 7.14 custom, **mainline llama.cpp b10791 — MTP now merged upstream**): 58 t/s, 128k ctx, q8_0 KV, `--spec-draft-p-min 0.8`, full serving config. Real daily-driver number.

Hipfire's own 154 t/s headline (localmaxxing): code-genre, Qwen**3.6** cross-genre draft, **3-bit asym3 KV**, 27-token prompt — superseded by our fair test above.

## 5. hipfire adoption notes

Setup friction (beta bugs, worked around here):
- Registry cache (`~/.hipfire/registry.cache.json`) omits the `dflash` sidecar for `qwen3.8:27b`/`-mq4-pro`/`-mq4-xt` despite upstream code comments declaring it — **patched cache JSON locally** (WED: re-apply after any registry refresh).
- `developer.dflash_draft` config key is not consulted by the serve pre-warm path.

Open questions: quality parity (MQ4V2 + DFlash2 math) via NIAH gate; code-class variance re-run; opencode end-to-end (tool formats, streaming, jinja) vs llama.cpp maturity.

## 6. Verdict table (Table C) — every lever tested

| Lever | Verdict | Evidence |
|---|---|---|
| Vulkan backend for MTP | **Adopt** | decode 2×+ vs HIP at every context (41.7 vs 19.0 at 81k) |
| MTP drafter, n-max 3 | **Adopt** | 44→70% acceptance tuned; mean len 2.46 ≈ cap |
| `--spec-draft-*` KV q4_0 | **Adopt** | what makes MTP+100k fit |
| Q4_K_M over Q4_K_XL | **Adopt** | +2.6% decode, better acceptance, smaller |
| `-b 2048 -ub 2048` | **Adopt** | +4.5% prefill |
| turbo4 KV on HIP | **Adopt (HIP only)** | best q4-class tier; aborts on Vulkan |
| HIP for prefill | Keep for C | 468 vs 430 t/s at 81k |
| MTP+100k on HIP | **Reject** | S4/S5 OOM (graceful + one hard crash) |
| turbo2/turbo2_tcq KV | **Reject (quality)** | sub-q4, below owner floor; no speed gain anyway |
| q8_0/f16 KV at 100k | **Reject (VRAM)** | 13+ GB KV + 17 GB model > card |
| amdvlk | **Reject** | deprecated; RADV matches record's prose |
| mtp-pflash fork | **Reject** | cannot load arch |
| MTP with plain f16 KV short ctx | Superseded | S2 (39.4) < V2 (65.9) |
| hipfire DFlash2 q8 | **Conditional** | +34% mixed mean, +110% tool, -17% prose; quality gate pending |
| hipfire asym3 KV | **Reject** | 3-bit, below floor; prefill 51 t/s |
| Qwen instruct sampling set (0.7/0.8/20/0/1.5) | **Adopt (web bench onward)** | guide-mandated; both engines re-dialed identically; earlier benches ran @llama defaults 0.8 — flagged |
| hipfire OpenAI tool calling | **Reject (v0.3.0 beta, root-caused)** | Qwen3.8 emits its native XML tool-call block; hipfire's `extract_tool_calls_from_text` (crates/hipfire-runtime/src/emit_text.rs, TOOL_CALL_OPEN const) only recognizes the Qwen3.5/3.6 legacy opener → no `tool_calls` field, plain text in `content`, `finish_reason: stop` (probe: `/tmp/opencode/hipfire-tools-probe.json`, stream+non-stream both). Docs (docs/SERVE.md) promise tool_calls but validation matrix was Qwen3.6 — arch-format gap, not config/template. Upstream fix: teach the emit layer the Qwen3.8 format. Plain-chat serving unaffected (fair test §3 stands) |
| Agent identity in stage-1 prompt | **Adopt (amended)** | run 1 (pre-amendment) confabulated a "4.2B on Raspberry Pi 5" persona from the label mnemonic `p5`; run 0 grounded correctly — stochastic; prompt now states full name + quant |

## 7. Phase status

| Phase | State |
|---|---|
| 0 smoke · 1 engine baseline · 2 drafter | Done |
| 3 quant sweep | Q4_K_M done; Q3_K_XL pulled, pending |
| 4 backend/lever tests | Done (Table C) |
| 5 agentic web build | **Pair + engine verdict done.** MTP vs control, same prompt+sampling: **1282 vs 1630 s (-21%)**, decode 45.5 vs 31.6 t/s (+44%), prefill 249.6 vs 195.5, MTP accept 72.1%, peak VRAM 23.1 vs 17.2 GiB. Quality = one-shot dice (MTP site FAIL: unclosed `<script>`; control site well-formed, renders). Undialed pair agreed on timing (1357/1743, -22%) but quality inverted — site quality is a dice roll at n=1; timing is the signal. **hipfire run VOIDED — no OpenAI tool_calls (plain-text tool calls) → unusable for pi/opencode.** Ladder answer for agentic serving: **Vulkan+MTP** |
| 6 quality gate | Not started |
