#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: Snap can only be packaged on macOS" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

swift build -c release --product Snap

BIN_DIR="$(swift build -c release --show-bin-path)"
BINARY="${BIN_DIR}/Snap"

if [[ ! -x "${BINARY}" ]]; then
  echo "error: expected release binary at ${BINARY}" >&2
  exit 1
fi

APP="${ROOT}/dist/Snap.app"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BINARY}" "${APP}/Contents/MacOS/Snap"
chmod +x "${APP}/Contents/MacOS/Snap"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"

# Ad-hoc sign so TCC can attach to the stable bundle identifier.
codesign --force --sign - --timestamp=none "${APP}"

echo "Built ${APP}"
