#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: Snap can only be packaged on macOS" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

pack_app_icon() {
    local source="$1"
    local dest="$2"
    local work iconset size name

    if [[ ! -f "${source}" ]]; then
        echo "error: missing app icon source ${source}" >&2
        exit 1
    fi

    work="$(mktemp -d)"
    iconset="${work}/AppIcon.iconset"
    mkdir -p "${iconset}"

    local specs=(
        "16:icon_16x16.png"
        "32:icon_16x16@2x.png"
        "32:icon_32x32.png"
        "64:icon_32x32@2x.png"
        "128:icon_128x128.png"
        "256:icon_128x128@2x.png"
        "256:icon_256x256.png"
        "512:icon_256x256@2x.png"
        "512:icon_512x512.png"
        "1024:icon_512x512@2x.png"
    )
    local spec
    for spec in "${specs[@]}"; do
        size="${spec%%:*}"
        name="${spec#*:}"
        sips -z "${size}" "${size}" "${source}" --out "${iconset}/${name}" >/dev/null
    done

    iconutil -c icns "${iconset}" -o "${dest}"
    rm -rf "${work}"
}

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
cp "${ROOT}/Resources/snap-icon.png" "${APP}/Contents/Resources/snap-icon.png"
pack_app_icon "${ROOT}/Resources/snap-icon.png" "${APP}/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so TCC can attach to the stable bundle identifier.
codesign --force --sign - --timestamp=none "${APP}"

echo "Built ${APP}"
