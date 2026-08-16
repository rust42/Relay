#!/usr/bin/env bash
# Invoked by the rust-core genrule (see rust-core/BUILD.bazel). Builds
# rust-core for macOS (arm64 + x86_64), lipos into a universal static lib,
# regenerates the UniFFI Swift bindings, then copies the results to the
# exact paths Bazel expects for the genrule's declared `outs`.
#
# Args: <out-lib.a> <out-charles_core.swift> <out-charles_coreFFI.h>
set -euo pipefail

# Resolve to absolute paths up front: they're relative to Bazel's execroot
# (the cwd at invocation), but we're about to `cd` into rust-core to run
# cargo, which would otherwise make these relative paths resolve wrong.
mkdir -p "$(dirname "$1")" "$(dirname "$2")" "$(dirname "$3")"
OUT_LIB="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUT_SWIFT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
OUT_HEADER="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"

# This script itself is a genrule `tool`, so it is not sandboxed away from
# the real checkout: resolve rust-core relative to this file's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_DIR="$ROOT_DIR/rust-core"

if [ -f "$HOME/.cargo/env" ]; then
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
fi
export PATH="$HOME/.cargo/bin:/usr/local/bin:$PATH"

cd "$CORE_DIR"

rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null 2>&1 || true

echo "==> building for aarch64-apple-darwin"
cargo build --release --target aarch64-apple-darwin

echo "==> building for x86_64-apple-darwin"
cargo build --release --target x86_64-apple-darwin

echo "==> lipo into universal static lib"
mkdir -p "$(dirname "$OUT_LIB")"
lipo -create \
  "target/aarch64-apple-darwin/release/libcharles_core.a" \
  "target/x86_64-apple-darwin/release/libcharles_core.a" \
  -output "$OUT_LIB"

echo "==> generating Swift bindings via uniffi-bindgen"
GEN_TMP="$(mktemp -d)"
cargo run --bin uniffi-bindgen -- generate \
  --library "target/aarch64-apple-darwin/release/libcharles_core.a" \
  --language swift \
  --out-dir "$GEN_TMP"

mkdir -p "$(dirname "$OUT_SWIFT")" "$(dirname "$OUT_HEADER")"
cp "$GEN_TMP/charles_core.swift" "$OUT_SWIFT"
cp "$GEN_TMP/charles_coreFFI.h" "$OUT_HEADER"
rm -rf "$GEN_TMP"

echo "==> done"
