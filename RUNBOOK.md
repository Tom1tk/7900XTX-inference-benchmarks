# RUNBOOK — 7900 XTX inference benchmarks

## Hard limits (read first)

1. **The desktop (Hyprland) shares the GPU.** Total card VRAM must stay ≤ ~21.5 GiB
   for comfort; configs that load to ~24.5 GiB (Vulkan MTP 100k) work but leave
   ~1.2 GiB — a browser-heavy desktop can push it over. A hard GPU reset recovers
   the card but kills the session (has happened once: a tinygrad OOM, and once a
   hipfire-adjacent llama.cpp hard OOM at 57k prefill).
2. **Never run tinygrad's 27B example with the GUI up.** TTY/SSH only.
3. Owner rule: **KV cache never above q4 quality** (turbo4/q4_0 tiers). Sub-q4
   tiers (turbo2/turbo2_tcq/hipfire asym3) are excluded unless gated by a quality
   check first.
4. llama.cpp OOMs are usually graceful (allocation failure → clean exit), but
   treat any near-limit config as display-crash risk. Check
   `journalctl -k | grep -i "amdgpu.*reset"` after any incident.

## Procedure for a web-bench run

1. Pick an unused index (see WEB_BENCH.md §5 port registry).
2. Kill any leftover engines: `pkill -f 'llama-serve[r]'; pkill -f 'hipfire serv[e]'`,
   verify `rocm-smi --showmeminfo vram` shows idle.
3. Run `./scripts/run-web-bench.sh <engine> <model> <label> <index> [args...]`.
   - hipfire runs: `thinking off` and speculation config are daemon-global — set
     with `hipfire config` first; the registry `dflash` sidecar patch from
     RESULTS.md §5 must be in place.
4. The script preflights free VRAM, live-guards the card at `VRAM_LIMIT_MIB`
   (default 22000), and commits+pushes pass or fail. A failed run is data.
5. After the run: review `sites/<label>/` by hand (quality table in WEB_BENCH.md
   §4), then update RESULTS.md's phase-5 table and the port registry.

## Work queue

### Open (awaiting owner go — no runs until owner says so)
1. **Quant × engine ladder, MTP on all** (owner policy: MTP everywhere, no downside observed):
   - buun-hip + **turbo4 KV** + MTP 64k, Q4_K_M — tests the TurboQuant draw directly (turbo4 is HIP-only; SET_ROWS aborts on Vulkan). Micro-bench says turbo4 ≈ q4_0 speed (tg128 33.00 vs 32.64) — the real value is VRAM headroom; verify at agentic workload.
   - mainline-hip + **Q3_K_XL** + MTP 64k (weights 12.24 GiB vs 15.33 → ~3 GiB headroom; candidate for a 100k+MTP attempt on the freed VRAM).
   - mainline-hip + Q4_K_XL + MTP 64k (completeness; early benches suggest ≈Q4_K_M).
   - build mainline **Vulkan** (`cmake -B build-vk -DGGML_VULKAN=ON`) → `mln-vk` backend-matched comparison.
2. **hipfire re-entry**: root cause is the emit-layer extractor only knowing Qwen3.5/3.6 tool-call format; Qwen3.8 XML unrecognized (RESULTS §6). Upstream checked: origin/beta == our build (7b16762); master is ahead but emit_text.rs byte-identical — **no fix exists upstream**. Only path: local patch of `crates/hipfire-runtime/src/emit_text.rs` (add the Qwen3.8 XML opener + body parser beside the legacy one) + cargo rebuild of the daemon, keeping the stock binary as fallback. Then re-run the ladder leg. KV modes available: q8, asym2/3/4, fwht2/3/4 — asym3 is 3-bit (below owner q4 floor → excluded unless gated; it's what the 154 t/s localmaxxing record used).
3. MTP context ceiling binary search (81k→100k, engine TBD).
4. `--spec-draft-n-max` / `--spec-draft-p-min` sweep.
5. Quality gate (NIAH) for q4_0/turbo4 KV and MQ4V2 — scheduled last on purpose.
6. tinygrad 27B from TTY (46 t/s claimed).

### Parked
- VBR dynamic KV (HIP only, may help MTP+100k headroom).
- Vulkan turbo-KV (blocked upstream: `SET_ROWS` op not implemented in buun's ggml-vulkan).

### Closed
- mtp-pflash-turboquant-hip fork (cannot load this arch; outdated).
- amdvlk (deprecated; RADV matches the record's prose decode).
- KV above q4 (owner rule).
- MTP+100k on HIP (does not fit; S4/S5).
- hipfire install + micro-bench fair test (done — RESULTS.md §5).

## Git protocol

Every run commits and pushes both artifacts and failures. Never reuse a port
index. One commit per run: `webbench: <label> — <outcome> (<s>, peak VRAM <MiB>, :<port>)`.
