#!/bin/zsh
set -euo pipefail

PIDS=($(pgrep -x desk-agent || true))
if (( ${#PIDS[@]} == 0 )); then
    echo "desk-agent is not running"
    exit 1
fi

for PID_VALUE in "${PIDS[@]}"; do
    ps -o pid=,rss=,%cpu=,etime=,command= -p "${PID_VALUE}"
    footprint "${PID_VALUE}" | sed -n '1,24p'
done
