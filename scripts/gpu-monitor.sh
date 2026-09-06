#!/usr/bin/env bash
# Sample GPU telemetry every INTERVAL seconds until killed.
# Output line format: HH:MM:SS vram_used_MiB|tempC_edge|clock_Mhz|util%
set -uo pipefail

INTERVAL="${INTERVAL:-5}"
ROCM_SMI="/opt/rocm/bin/rocm-smi"
[[ -x "$ROCM_SMI" ]] || ROCM_SMI=$(command -v rocm-smi)

while true; do
    VRAM=$("$ROCM_SMI" --showmeminfo vram 2>/dev/null | awk '/Total Used/ {print int($8/1048576)}')
    STATS=$("$ROCM_SMI" --showtemp --showclocks --showuse 2>/dev/null | awk '
        /Temperature \(S\)/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9.]+c$/ || $i ~ /c$/) t=$i }
        /Average Clocks/   { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) c=$i }
        /GPU use/          { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+%$/) u=$i }
        END { print t, c, u }' | tr ' ' '|')
    printf '%s %s|%s\n' "$(date +%H:%M:%S)" "${VRAM:-?}" "${STATS:-?|?}"
    sleep "$INTERVAL"
done
