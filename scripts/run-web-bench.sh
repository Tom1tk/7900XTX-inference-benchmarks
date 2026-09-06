#!/usr/bin/env bash
# Agentic web-build benchmark for one model/engine version on the 7900 XTX.
#
# Usage: ./scripts/run-web-bench.sh <engine> <model-spec> <label> <index> [quant] [extra engine args...]
#   engine      buun-vk | buun-hip | hipfire
#   model-spec  path to a .gguf (buun engines) or hipfire registry tag (hipfire)
#   label       e.g. p5-vk-q4km-mtp   (folder and commit message both key off this)
#   index       0,1,2,... unique per model version. Every port derives from it, so
#               each site stays hosted after its run instead of fighting for :4000.
#   quant       optional, substituted into the stage-1 prompt as {{QUANT}}
#               (default Q4_K_M; must not start with '-')
#
# Drives `pi` through the three prompts in prompts/web-bench.md against the
# engine, recording per-request prefill/decode throughput via
# scripts/web_bench_metrics.py.
#
# Commits and pushes on both success and failure. A failed run is data.
#
# VRAM caveat: the desktop (Hyprland) shares this GPU. The script preflights
# idle VRAM, monitors usage live, and kills the run if the card would overflow.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# --- Fixed parameters (see WEB_BENCH.md) ------------------------------------
CTX="${CTX:-65536}"   # 32768 overflowed at stage 2 (pi 0.85 request hit 32827 tok)
STAGE_TIMEOUT="${STAGE_TIMEOUT:-3600}"
LOAD_TIMEOUT="${LOAD_TIMEOUT:-600}"
VRAM_LIMIT_MIB="${VRAM_LIMIT_MIB:-22000}"   # live guard: total card usage limit
# Qwen3.8 instruct-mode sampling (unsloth/Qwen3.8-27B-GGUF "Best Practices":
# temp 0.7, top_p 0.80, top_k 20, min_p 0.0, presence 1.5, repeat 1.0).
# llama.cpp defaults (0.8/0.95/40/0.05/0) are NOT the recommended set.
ROCM_SMI="/opt/rocm/bin/rocm-smi"

# --- Arguments --------------------------------------------------------------
if [[ $# -lt 4 ]]; then
    sed -n '2,12p' "$0" >&2
    exit 2
fi

ENGINE="$1"; MODEL="$2"; LABEL="$3"; IDX="$4"; shift 4

# Optional 5th positional arg: quant name for the {{QUANT}} prompt substitution.
# Anything not starting with '-' is taken as the quant; the rest are engine args.
QUANT="Q4_K_M"
if [[ $# -gt 0 && "$1" != -* ]]; then
    QUANT="$1"
    shift
fi
EXTRA_ARGS=("$@")

[[ "$IDX" =~ ^[0-9]+$ ]] || { echo "ERROR: index must be a non-negative integer, got '$IDX'" >&2; exit 2; }

HIP_ROOT="/home/tom/.hipfire"
BUUN_VK="/home/tom/Documents/buun-llama-cpp/build-vk/bin/llama-server"
BUUN_HIP="/home/tom/Documents/buun-llama-cpp/build/bin/llama-server"

case "$ENGINE" in
    buun-vk)
        BIN="$BUUN_VK"
        [[ -x "$BIN" ]] || { echo "ERROR: $BIN not found (build it with -DGGML_VULKAN=ON)" >&2; exit 2; }
        [[ -f "$MODEL" ]] || { echo "ERROR: model not found: $MODEL" >&2; exit 2; }
        ;;
    buun-hip)
        BIN="$BUUN_HIP"
        [[ -x "$BIN" ]] || { echo "ERROR: $BIN not found" >&2; exit 2; }
        [[ -f "$MODEL" ]] || { echo "ERROR: model not found: $MODEL" >&2; exit 2; }
        ;;
    hipfire)
        export PATH="${HIP_ROOT}/bin:$PATH"
        command -v hipfire >/dev/null || { echo "ERROR: hipfire not on PATH" >&2; exit 2; }
        ;;
    *) echo "ERROR: unknown engine '$ENGINE' (expected buun-vk|buun-hip|hipfire)" >&2; exit 2 ;;
esac

command -v pi >/dev/null || { echo "ERROR: pi not on PATH" >&2; exit 2; }

# --- Ports ------------------------------------------------------------------
SITE_PORT=$((4000 + IDX))
SERVER_PORT=$((8100 + IDX))
PROXY_PORT=$((8200 + IDX))

for port in "$SITE_PORT" "$SERVER_PORT" "$PROXY_PORT"; do
    if ss -ltn 2>/dev/null | grep -q ":${port}\b"; then
        echo "ERROR: port $port is already in use - pick a different index" >&2
        ss -ltnp 2>/dev/null | grep ":${port}\b" >&2
        exit 1
    fi
done

# --- Paths ------------------------------------------------------------------
mkdir -p logs results/web sites prompts
SERVER_LOG="logs/${LABEL}.server.log"
AGENT_LOG="logs/${LABEL}.agent.log"
VRAM_LOG="logs/${LABEL}.vram.log"
METRICS="results/web/${LABEL}.jsonl"
STAGE_TIMES="results/web/${LABEL}.stages.json"
SUMMARY="results/web/${LABEL}.json"
AGGREGATE="results/web-bench.csv"
SITE_DIR="sites/${LABEL}"
PI_DIR="${SITE_DIR}/.pi-agent"

rm -f "$METRICS" "${METRICS}.stage"
mkdir -p "$SITE_DIR" "$PI_DIR"

# --- Preflight: the GUI shares this card ------------------------------------
echo "=== preflight ==="
vram_used_mib() {
    # rocm-smi column offsets differ between the Total and Used lines
    # (Total: $7, Used: $8 - the extra "Used" word shifts the number).
    "$ROCM_SMI" --showmeminfo vram 2>/dev/null \
        | awk '/Total Used/ {u=int($8/1048576)} END {print u}'
}
VRAM_TOTAL=$(awk '/Total Memory/ {print int($7/1048576)}' < <("$ROCM_SMI" --showmeminfo vram 2>/dev/null))
VRAM_USED=$(vram_used_mib)
echo "VRAM: ${VRAM_USED}/${VRAM_TOTAL} MiB used | site :$SITE_PORT | engine :$SERVER_PORT | proxy :$PROXY_PORT"
FREE=$(( VRAM_TOTAL - VRAM_USED ))
# Rough floor: 24 GB-class card must leave >= 4 GiB for the desktop + headroom.
if [[ "$FREE" -lt 7000 ]]; then
    echo "ERROR: only ${FREE} MiB VRAM free - close other GPU workloads first" >&2
    exit 1
fi

# --- Teardown ---------------------------------------------------------------
SERVER_PID=""; PROXY_PID=""; MONITOR_PID=""
cleanup() {
    for pid in "$PROXY_PID" "$SERVER_PID" "$MONITOR_PID"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    done
}
trap cleanup EXIT

# --- Live VRAM guard --------------------------------------------------------
# Polls total card usage; if it would breach VRAM_LIMIT_MIB, abort the run
# before the desktop loses VRAM (a llama.cpp OOM is graceful, a desktop crash is not).
guard_loop() {
    while kill -0 "$$" 2>/dev/null; do
        U=$(vram_used_mib)
        if [[ -n "$U" && "$U" -gt "$VRAM_LIMIT_MIB" ]]; then
            echo "VRAM-GUARD: ${U} MiB used > limit ${VRAM_LIMIT_MIB} - aborting run" >> "$VRAM_LOG"
            kill "$SERVER_PID" 2>/dev/null
            pkill -P $$ 2>/dev/null
            exit 99
        fi
        sleep 5
    done
}

# --- Telemetry --------------------------------------------------------------
INTERVAL=5 ./scripts/gpu-monitor.sh > "$VRAM_LOG" 2>/dev/null &
MONITOR_PID=$!

# --- Start engine -----------------------------------------------------------
OUTCOME=""
START=$(date +%s)

if [[ "$ENGINE" == "hipfire" ]]; then
    # hipfire: daemon handles its own chat templates; model-spec is a registry tag.
    # Its config (thinking off, speculation on) is global daemon config - set via
    # `hipfire config` before the run; the script only fixes the port.
    echo "=== starting hipfire: $LABEL ==="
    hipfire serve "$MODEL" --kv-mode "${HIPFIRE_KV_MODE:-q8}" --idle-timeout 0 -d \
        > "$SERVER_LOG" 2>&1
    # -d daemonizes and logs to ~/.hipfire/serve.log; wait for the API
    UPSTREAM_PORT="${HIPFIRE_PORT:-$SERVER_PORT}"
    deadline=$(( $(date +%s) + LOAD_TIMEOUT ))
    until curl -sf -m 5 "http://127.0.0.1:${UPSTREAM_PORT}/v1/models" >/dev/null 2>&1; do
        if [[ $(date +%s) -gt $deadline ]]; then
            echo "ERROR: hipfire not healthy after ${LOAD_TIMEOUT}s - last 30 lines:" >&2
            tail -30 ~/.hipfire/serve.log >&2
            OUTCOME="FAILED(load)"
            break
        fi
        sleep 5
    done
    SERVER_PID=$(cat ~/.hipfire/serve.pid 2>/dev/null || echo "")
else
    # llama.cpp engines: --jinja is required for tool calls.
    SERVER_CMD=(
        "$BIN" -m "$MODEL"
        --host 127.0.0.1 --port "$SERVER_PORT"
        -ngl 999 -fa on -t 8
        -b 2048 -ub 2048
        -c "$CTX"
        --temp 0.7 --top-p 0.8 --top-k 20 --min-p 0.0 --presence-penalty 1.5
        --jinja --no-mmproj --parallel 1
        "${EXTRA_ARGS[@]}"
    )
    if [[ "$ENGINE" == "buun-vk" ]]; then
        export GGML_VK_ALLOW_GRAPHICS_QUEUE=1
    fi

    echo "=== starting server: $LABEL ==="
    printf '%q ' "${SERVER_CMD[@]}"; echo

    "${SERVER_CMD[@]}" > "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!

    deadline=$(( $(date +%s) + LOAD_TIMEOUT ))
    until curl -sf -m 5 "http://127.0.0.1:${SERVER_PORT}/health" >/dev/null 2>&1; do
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "ERROR: server exited during load - last 30 lines:" >&2
            tail -30 "$SERVER_LOG" >&2
            OUTCOME="FAILED(load)"
            break
        fi
        if [[ $(date +%s) -gt $deadline ]]; then
            echo "ERROR: server not healthy after ${LOAD_TIMEOUT}s" >&2
            OUTCOME="FAILED(timeout)"
            break
        fi
        sleep 5
    done
    UPSTREAM_PORT="$SERVER_PORT"
fi

# --- Agent stages -----------------------------------------------------------
declare -A STAGE_SECONDS=()
if [[ -z "$OUTCOME" ]]; then
    LOAD_SECONDS=$(( $(date +%s) - START ))
    echo "=== engine healthy after ${LOAD_SECONDS}s ==="

    guard_loop &
    GUARD_PID=$!
    MONITOR_PID="$MONITOR_PID $GUARD_PID"

    python3 ./scripts/web_bench_metrics.py proxy \
        --listen "$PROXY_PORT" --upstream "127.0.0.1:${UPSTREAM_PORT}" --out "$METRICS" \
        >> "$SERVER_LOG" 2>&1 &
    PROXY_PID=$!
    sleep 2

    # Isolated pi config: never touch the operator's pi settings.
    cat > "${PI_DIR}/models.json" <<EOF
{
  "providers": {
    "webbench": {
      "baseUrl": "http://127.0.0.1:${PROXY_PORT}/v1",
      "api": "openai-completions",
      "apiKey": "none",
      "models": [ { "id": "${LABEL}", "name": "${LABEL}" } ]
    }
  }
}
EOF

    OUTCOME="ok"
    for STAGE in 1 2 3; do
        PROMPT=$(awk "/<!-- STAGE ${STAGE} -->/{f=1;next} /<!-- END STAGE ${STAGE} -->/{f=0} f" \
                     prompts/web-bench.md \
                 | sed -e "s|{{MODEL_NAME}}|${LABEL}|g" -e "s|{{PORT}}|${SITE_PORT}|g" -e "s|{{QUANT}}|${QUANT}|g")
        if [[ -z "${PROMPT// }" ]]; then
            echo "ERROR: stage ${STAGE} prompt is empty - check prompts/web-bench.md markers" >&2
            OUTCOME="FAILED(prompt)"
            break
        fi

        echo "$STAGE" > "${METRICS}.stage"
        echo "=== stage ${STAGE} ==="
        S0=$(date +%s)
        # --continue keeps stages 2 and 3 in the same session, so the agent sees
        # the site it already built rather than rediscovering it.
        PI_ARGS=(--provider webbench --model "$LABEL" --session-dir "${PI_DIR}/sessions" -p)
        [[ "$STAGE" -gt 1 ]] && PI_ARGS=(--continue "${PI_ARGS[@]}")

        ( cd "$SITE_DIR" && PI_OFFLINE=1 PI_CODING_AGENT_DIR="${REPO}/${PI_DIR}" \
            timeout "$STAGE_TIMEOUT" pi "${PI_ARGS[@]}" "$PROMPT" ) \
            >> "$AGENT_LOG" 2>&1
        STATUS=$?
        STAGE_SECONDS[$STAGE]=$(( $(date +%s) - S0 ))
        echo "stage ${STAGE}: ${STAGE_SECONDS[$STAGE]}s (exit ${STATUS})"

        if [[ "$STATUS" -ne 0 ]]; then
            echo "ERROR: stage ${STAGE} exited ${STATUS} (124 = hit the ${STAGE_TIMEOUT}s timeout)" >&2
            tail -20 "$AGENT_LOG" >&2
            OUTCOME="FAILED(stage${STAGE})"
            break
        fi
    done
    ELAPSED=$(( $(date +%s) - START ))
fi

kill "$PROXY_PID" 2>/dev/null; PROXY_PID=""
[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""
if [[ "$ENGINE" == "hipfire" ]]; then
    hipfire serve stop >/dev/null 2>&1 || pkill -f 'hipfire serv[e]' 2>/dev/null
fi
for pid in $MONITOR_PID; do kill "$pid" 2>/dev/null; done
MONITOR_PID=""
trap - EXIT

# --- Telemetry summary ------------------------------------------------------
PEAK_VRAM=$(awk -F'|' '{
    split($1, v, " "); val = v[2] + 0
    if (val > max) max = val
} END { print (max ? max : "n/a") }' "$VRAM_LOG")

echo "=== finished in ${ELAPSED:-?}s | ${OUTCOME} | peak VRAM ${PEAK_VRAM} MiB ==="
if [[ "$PEAK_VRAM" != "n/a" && "$PEAK_VRAM" -gt "$VRAM_LIMIT_MIB" ]]; then
    echo "WARNING: peak ${PEAK_VRAM} MiB breached the ${VRAM_LIMIT_MIB} MiB limit - treat numbers as suspect and record it in the runlog." >&2
fi

# --- Summarize --------------------------------------------------------------
{
    printf '{'
    sep=""
    for stage in "${!STAGE_SECONDS[@]}"; do
        printf '%s"%s": %s' "$sep" "$stage" "${STAGE_SECONDS[$stage]}"
        sep=", "
    done
    printf '}\n'
} > "$STAGE_TIMES"

python3 ./scripts/web_bench_metrics.py summarize \
    --metrics "$METRICS" --stage-times "$STAGE_TIMES" \
    --label "$LABEL" --engine "$ENGINE" --model "$MODEL" \
    --site-port "$SITE_PORT" --total-seconds "${ELAPSED:-0}" \
    --out "$SUMMARY" --csv "$AGGREGATE"

echo
echo "Site should now be live at http://localhost:${SITE_PORT}"
curl -sf -m 5 -o /dev/null "http://localhost:${SITE_PORT}" && echo "confirmed: site responds" || echo "NOTE: site is not responding - the agent may not have completed stage 1"

# --- Commit and push (mandatory, pass or fail) ------------------------------
git add -A
if git diff --cached --quiet; then
    echo "nothing to commit"
else
    git commit -q -m "webbench: ${LABEL} — ${OUTCOME} (${ELAPSED:-?}s, peak VRAM ${PEAK_VRAM} MiB, :${SITE_PORT})"
    git push -q && echo "pushed" || echo "WARNING: push failed; commit is local" >&2
fi

echo
echo "Next: update RESULTS.md Phase 5 table and WEB_BENCH.md's port registry."

[[ "$OUTCOME" == "ok" ]]
