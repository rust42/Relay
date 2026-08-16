#!/usr/bin/env bash
# Builds rust-core for macOS (arm64 + x86_64), lipos into a universal
# static lib, and regenerates the Swift/UniFFI bindings consumed by the
# Xcode project. Run manually, or via the pre-build script wired up in
# Project.swift.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT_DIR/rust-core"
OUT_DIR="$CORE_DIR/target/universal"
GEN_DIR="$CORE_DIR/generated/swift"

cd "$CORE_DIR"

# Ensure `cargo` (and rustup/uniffi) are available when this script
# is run from Xcode's non-login build shell. Prefer sourcing the
# user's cargo env if present, and also prepend common install paths.
if [ -f "$HOME/.cargo/env" ]; then
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
fi
export PATH="$HOME/.cargo/bin:/usr/local/bin:$PATH"

rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null 2>&1 || true

echo "==> building for aarch64-apple-darwin"
cargo build --release --target aarch64-apple-darwin

echo "==> building for x86_64-apple-darwin"
cargo build --release --target x86_64-apple-darwin

mkdir -p "$OUT_DIR"
echo "==> lipo into universal static lib"
lipo -create \
  "target/aarch64-apple-darwin/release/librelay_core.a" \
  "target/x86_64-apple-darwin/release/librelay_core.a" \
  -output "$OUT_DIR/librelay_core.a"

echo "==> generating Swift bindings via uniffi-bindgen"
mkdir -p "$GEN_DIR"
# uniffi-bindgen cannot extract members from a fat (lipo) .a archive,
# so run it against one architecture slice instead (any valid slice will do).
cargo run --bin uniffi-bindgen -- generate \
  --library "target/aarch64-apple-darwin/release/librelay_core.a" \
  --language swift \
  --out-dir "$GEN_DIR"

# Swift resolves `import relay_coreFFI` via module.modulemap on the include
# path, so mirror the generated modulemap under that name.
command cp -f "$GEN_DIR/relay_coreFFI.modulemap" "$GEN_DIR/module.modulemap"

echo "==> done. Universal lib: $OUT_DIR/librelay_core.a"
echo "    Swift bindings:     $GEN_DIR"
