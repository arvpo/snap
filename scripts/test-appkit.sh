#!/bin/bash
# Run the complete test catalog in a real AppKit loop. Some CLT SwiftPM
# helpers exit with status 0 before asynchronous UI tests finish.
set -euo pipefail
cd "$(dirname "$0")/.."

build_dir=$(mktemp -d "${TMPDIR:-/tmp}/snap-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="$build_dir/ModuleCache"
swift_args=(--build-system native --disable-sandbox --scratch-path "$build_dir/build"
    --cache-path "$build_dir/PackageCache"
    -Xswiftc -module-cache-path -Xswiftc "$CLANG_MODULE_CACHE_PATH")
swift build --build-tests "${swift_args[@]}"
products=$(swift build --show-bin-path "${swift_args[@]}")

cat > "$build_dir/Runner.swift" <<'SWIFT'
import AppKit
@main
struct AppKitTestRunner {
    @MainActor static func main() {
        let application = NSApplication.shared
        Task { @MainActor in await __swiftPMEntryPoint() }
        application.run()
        // Only a completed test catalog may exit successfully.
        exit(EXIT_FAILURE)
    }
}
SWIFT

test_sources=()
while IFS= read -r -d '' source; do
    test_sources+=("$source")
done < <(find Tests/SnapTests -name '*.swift' -print0)
swiftc -parse-as-library -swift-version 6 -module-name SnapAppKitTests \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" -I "$products/Modules" \
    "${test_sources[@]}" "$build_dir/Runner.swift" "$products"/SnapCore.build/*.o \
    -o "$build_dir/RunTests"
"$build_dir/RunTests"
