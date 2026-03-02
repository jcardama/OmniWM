#!/usr/bin/env bash
# build-zig.sh — compile zig/omni_layout.zig into .build/zig/libomni_layout.a
#
# Run this once before `swift build`.  The Makefile `zig-build` target calls it.
#
# Architecture: defaults to aarch64 (Apple Silicon). Override with ZIG_TARGET:
#   ZIG_TARGET=x86_64-macos ./build-zig.sh
set -euo pipefail

ZIG_TARGET="${ZIG_TARGET:-aarch64-macos}"
OUT_DIR=".build/zig"
OUT_LIB="${OUT_DIR}/libomni_layout.a"
SRC="zig/omni_layout.zig"

if ! command -v zig &> /dev/null; then
    echo "error: zig not found in PATH — install from https://ziglang.org/download/" >&2
    exit 1
fi

echo "▸ zig build-lib  target=${ZIG_TARGET}  out=${OUT_LIB}"
mkdir -p "${OUT_DIR}"

zig build-lib \
    -O ReleaseFast \
    -target "${ZIG_TARGET}" \
    -femit-bin="${OUT_LIB}" \
    -fno-emit-h \
    "${SRC}"

echo "✓ ${OUT_LIB}"
