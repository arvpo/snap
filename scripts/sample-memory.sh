#!/usr/bin/env bash
# Sample resident memory for a running Snap process, or launch dist/Snap.app
# long enough to measure idle RSS after launch settles.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-2}"

rss_mb() {
  local pid="$1"
  local rss_kb
  rss_kb="$(ps -o rss= -p "${pid}" | tr -d ' ')"
  if [[ -z "${rss_kb}" ]]; then
    echo "error: process ${pid} has no RSS" >&2
    return 1
  fi
  awk -v kb="${rss_kb}" 'BEGIN { printf "%.1f\n", kb / 1024 }'
}

report() {
  local pid="$1"
  local extra="${2:-}"
  echo "rss $(rss_mb "${pid}") MB (pid ${pid}${extra})"
  if command -v footprint >/dev/null; then
    footprint -s "${pid}" | awk '/phys_footprint:/ { print "footprint " $2, $3 }'
  fi
}

if [[ "${1:-}" == "--launch" ]]; then
  APP="${ROOT}/dist/Snap.app/Contents/MacOS/Snap"
  if [[ ! -x "${APP}" ]]; then
    echo "error: ${APP} is missing; run ./scripts/build-app.sh first" >&2
    exit 1
  fi
  "${APP}" &
  pid=$!
  sleep "${SAMPLE_SECONDS}"
  if ! kill -0 "${pid}" 2>/dev/null; then
    echo "error: Snap exited before the idle sample" >&2
    exit 1
  fi
  report "${pid}" ", settled ${SAMPLE_SECONDS}s"
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  exit 0
fi

if [[ $# -ge 1 ]]; then
  pid="$1"
else
  pid="$(pgrep -nx Snap || true)"
fi

if [[ -z "${pid}" ]]; then
  echo "error: no Snap process found; pass a pid or use --launch" >&2
  exit 1
fi

report "${pid}"
