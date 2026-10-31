#!/usr/bin/env bash
# Fetches llama.cpp's prebuilt iOS framework (local AI code completion) into third_party/llama.
# Pinned to a release and checked against its SHA-256; only the ios-arm64 slice is kept.
#
# usage: scripts/fetch-llama.sh
set -euo pipefail

TAG=b11960   # same commit as llama.cpp v0.8.0
SHA256=feba05e0b7cb5e682ae3354abb455bf9723ae2cc95c69e24d073264e6a34d759

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/third_party/llama"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/llama.zip" \
  "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-xcframework.zip"
echo "$SHA256  $WORK/llama.zip" | shasum -a 256 -c -

unzip -q "$WORK/llama.zip" "build-apple/llama.xcframework/ios-arm64/llama.framework/*" -d "$WORK"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$WORK/build-apple/llama.xcframework/ios-arm64/llama.framework" "$OUT/"
echo "$TAG" > "$OUT/LLAMA_TAG"
echo "llama.cpp $TAG -> $OUT/llama.framework"
