#!/usr/bin/env bash
# dev.sh — build Zig lib, then build (and optionally run) OmniWM
#
# Usage:
#   ./dev.sh          # zig build + swift build
#   ./dev.sh --run    # zig build + swift build + run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "==> Building Zig library"
./build-zig.sh

echo "==> Building OmniWM"
swift build

if [[ "${1:-}" == "--run" ]]; then
    echo "==> Running OmniWM"
    swift run
fi
