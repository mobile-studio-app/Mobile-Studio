#!/usr/bin/env bash
# Fetches CPython for iOS (BeeWare's Python-Apple-support) into third_party/python, for the
# Python runtime. Pinned to a release and checked against its SHA-256. The app's build copies
# the standard library into the bundle and wraps its binary modules as frameworks
# (scripts/install-python.sh).
#
# usage: scripts/fetch-python.sh
set -euo pipefail

TAG=3.14-b12   # Python 3.14.8
ASSET=Python-3.14-iOS-support.b12.tar.gz
SHA256=157a6b956f47a12f005ad1e23e3e264536ef06dd35e1366acb48edbaa128e0a3

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/third_party/python"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/python.tar.gz" \
  "https://github.com/beeware/Python-Apple-support/releases/download/$TAG/$ASSET"
echo "$SHA256  $WORK/python.tar.gz" | shasum -a 256 -c -

mkdir -p "$WORK/x"
tar -xzf "$WORK/python.tar.gz" -C "$WORK/x"
rm -rf "$OUT"
mkdir -p "$OUT"
# Only the device slice and the shared stdlib; the simulator slice isn't used.
cp -R "$WORK/x/Python.xcframework" "$OUT/"
rm -rf "$OUT/Python.xcframework/ios-arm64_x86_64-simulator"
/usr/libexec/PlistBuddy -c "Delete :AvailableLibraries:1" "$OUT/Python.xcframework/Info.plist" 2>/dev/null || true
echo "$TAG" > "$OUT/PYTHON_TAG"
echo "Python $TAG -> $OUT/Python.xcframework"
