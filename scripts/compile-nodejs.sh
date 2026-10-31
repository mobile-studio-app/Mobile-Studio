#!/usr/bin/env bash
# Compiles Node.js for iOS (nodejs-mobile) with ICU into static libraries in
# third_party/nodejs-libs; scripts/build-nodejs.sh links them into NodeMobile.framework.
# Separate so CI can cache this half, which takes about 25 minutes.
#
# nodejs-mobile's own iOS build has no ICU (--with-intl=none): no Intl, and regular
# expressions with \p{...} don't compile, which stops extensions such as Claude Code from
# starting. This is the same release with small-icu (all of Unicode's character data, English
# locale data), configured as nodejs-mobile's tools/ios_framework_prepare.sh does otherwise:
# arm64 device only, V8 without JIT.
#
# Needs Xcode 15 or 16 (Xcode 26's Clang rejects parts of V8 10.2) and Python 3.11 or older.
# usage: scripts/compile-nodejs.sh
set -euo pipefail

TAG=v18.20.4

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/third_party/nodejs-libs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --quiet --depth 1 --branch "$TAG" https://github.com/nodejs-mobile/nodejs-mobile.git "$WORK/node"
cd "$WORK/node"
# ICU's build tools have to be built for the Mac, as V8's are.
python3 "$ROOT/scripts/patch-nodejs-host-tools.py" common.gypi

# configure.py needs distutils, which Python 3.12 dropped; setuptools brings it back. It's run
# with this Python directly, since ./configure picks its own from a list.
python3 --version
python3 -m venv "$WORK/venv"
source "$WORK/venv/bin/activate"
python -m pip install --quiet setuptools
python -c "import distutils" || { echo "distutils isn't available to configure.py"; exit 1; }

export GYP_DEFINES="target_arch=arm64 host_os=mac target_os=ios"
# V8 10.2 converts out-of-range values to enums in constant expressions, an error in Clang 16+
# (Xcode 16) that can still be turned off. For the iOS build and the Mac tools alike.
export CXXFLAGS="-Wno-enum-constexpr-conversion" CXXFLAGS_host="-Wno-enum-constexpr-conversion"
# No debug info (these come after the build's -gdwarf-2): V8's runs to gigabytes, more than a
# CI runner's disk holds, and the framework is stripped anyway.
export CFLAGS="-g0" CFLAGS_host="-g0" CXXFLAGS="$CXXFLAGS -g0" CXXFLAGS_host="$CXXFLAGS_host -g0"
python configure.py \
  --dest-os=ios \
  --dest-cpu=arm64 \
  --with-intl=small-icu \
  --cross-compiling \
  --enable-static \
  --openssl-no-asm \
  --v8-options=--jitless \
  --without-node-code-cache \
  --without-node-snapshot
make -j"$(sysctl -n hw.ncpu)"

rm -rf "$OUT"
mkdir -p "$OUT"
cp out/Release/*.a "$OUT/"
ls -la "$OUT"
