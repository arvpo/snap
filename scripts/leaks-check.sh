#!/usr/bin/env bash
# Run macOS `leaks` against a live Snap process after a repeat-capture session.
# Any definitely lost allocation rooted in Snap code is a release blocker.
set -euo pipefail

if ! command -v leaks >/dev/null; then
  echo "error: leaks(1) is not available on this machine" >&2
  exit 1
fi

if [[ $# -ge 1 ]]; then
  pid="$1"
else
  pid="$(pgrep -nx Snap || true)"
fi

if [[ -z "${pid}" ]]; then
  echo "error: no Snap process found; pass the pid after a 50-cycle session" >&2
  exit 1
fi

echo "Checking leaks for Snap pid ${pid}"
leaks --list "${pid}"
