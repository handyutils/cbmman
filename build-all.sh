#!/usr/bin/env bash
set -euo pipefail
VERSION=$(grep -m1 '^version =' Cargo.toml | sed 's/.*"\(.*\)".*/\1/')
TARGETS=(
  aarch64-apple-darwin
  x86_64-apple-darwin
  x86_64-unknown-linux-gnu
  aarch64-unknown-linux-gnu
  x86_64-pc-windows-msvc
)

for target in "${TARGETS[@]}"; do
  echo "==> Building $target"
  cargo build --release --locked --target "$target"
  mkdir -p "dist/$target"
  if [[ "$target" == *windows* ]]; then
    cp "target/$target/release/cbmman.exe" "dist/$target/cbmman-$target.exe"
  else
    cp "target/$target/release/cbmman" "dist/$target/cbmman-$target"
  fi
done

echo "==> Artifacts in dist/"
ls -lh dist/
