#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 0.1.3"
  exit 1
fi

VERSION="$1"
if [[ ! "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must be semver, e.g. 0.1.3"
  exit 1
fi
TAG="v${VERSION#v}"

echo "==> Bumping version to $TAG in Cargo.toml"
if grep -q '^version = ' Cargo.toml; then
  sed -i.bak "s/^version = \".*\"$/version = \"$TAG\"/" Cargo.toml
  rm -f Cargo.toml.bak
else
  echo "Error: version not found in Cargo.toml"
  exit 1
fi

echo "==> Committing version bump"
git add Cargo.toml
git commit -m "chore: bump version to $TAG"

echo "==> Creating tag $TAG"
git tag "$TAG"

echo "==> Pushing to origin"
git push origin main
git push origin "$TAG"

echo "==> Done. GitHub Actions release workflow will now build and publish."
