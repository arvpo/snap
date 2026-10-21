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
# Optional diagnostic run. Keep leak-tool exit status and complete allocation
# stacks; a nonzero result must be investigated, never converted into a pass.
if [[ "${SNAP_TEST_LEAKS:-0}" == "1" ]]; then
    leak_status=0
    SNAP_TEST_RESULT_PATH="$build_dir/test-result" MallocStackLogging=1 \
        leaks --atExit -- "$build_dir/RunTests" || leak_status=$?
    if [[ ! -f "$build_dir/test-result" ]] || [[ "$(cat "$build_dir/test-result")" != "0" ]]; then
        echo "error: test catalog failed or did not complete under leaks" >&2
        exit 1
    fi
    exit "$leak_status"
else
    "$build_dir/RunTests"
fi
