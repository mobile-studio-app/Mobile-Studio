#!/usr/bin/env bash
# Build LÖVE 12 (liblove) for iOS devices and stage it, with its prebuilt
# dependencies, into third_party/love12-ios for the LoveRuntime12 target.
# CI caches the staged folder keyed on this file, so bumping a pin rebuilds.
#
# usage: scripts/build-love-ios.sh        (macOS with Xcode only)
set -euo pipefail

# Pinned sources. LÖVE 12.0 is unreleased; bump these deliberately.
LOVE_REPO=https://github.com/love2d/love.git
LOVE_SHA=ef388d4371f5932491fbdcdd65ac7240e11c31a8          # main, 2026-10-25
DEPS_REPO=https://github.com/love2d/love-apple-dependencies.git
DEPS_SHA=a5522634f1e581a1ebab73bf3ab4bd7a853b7a3e          # main (used by LÖVE's own iOS CI)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/third_party/src"
OUT="$ROOT/third_party/love12-ios"

# Shallow fetch of one commit; extra args become a sparse-checkout path list.
fetch() {
  local repo="$1" sha="$2" dir="$3"; shift 3
  rm -rf "$dir"
  git init -q "$dir"
  git -C "$dir" remote add origin "$repo"
  if [ "$#" -gt 0 ]; then
    git -C "$dir" sparse-checkout set --no-cone "$@"
  fi
  git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$sha"
  git -C "$dir" checkout -q FETCH_HEAD
}

echo "Fetching LÖVE $LOVE_SHA"
fetch "$LOVE_REPO" "$LOVE_SHA" "$WORK/love"
echo "Fetching love-apple-dependencies $DEPS_SHA (iOS + shared only)"
fetch "$DEPS_REPO" "$DEPS_SHA" "$WORK/deps" "/iOS/libraries/" "/shared/"

# Compile shaders on iOS the way LÖVE does on macOS. Upstream checks iOS shaders as GLSL ES 3.20,
# which rejects desktop GLSL that PC games ship with (uniform initialisers, int-to-float
# conversions, ...). The Metal backend translates SPIR-V to MSL for iOS either way, so desktop
# GLSL works there just as it does on a Mac. Each patch must apply, or the build stops.
echo "Patching LÖVE: desktop GLSL rules for Metal shaders on iOS"
python3 - "$WORK/love" <<'PY'
import re, sys
root = sys.argv[1]
patches = [
    ("src/modules/graphics/metal/Graphics.mm",
     r"bool Graphics::usesGLSLES\(\) const\s*\{\s*#ifdef LOVE_IOS\s*return true;\s*#else\s*return false;\s*#endif\s*\}",
     "bool Graphics::usesGLSLES() const\n{\n\treturn false; // DuoCode: desktop GLSL on iOS too\n}"),
    ("src/modules/graphics/metal/Shader.mm",
     r"#ifdef LOVE_IOS\s*defaultversion = 320;\s*defaultprofile = EEsProfile;\s*forcedefault = true;\s*#endif",
     "// DuoCode: no GLSL ES override on iOS"),
]
for path, pattern, replacement in patches:
    full = f"{root}/{path}"
    text = open(full).read()
    patched, count = re.subn(pattern, replacement, text)
    if count != 1:
        sys.exit(f"::error::LÖVE patch didn't apply to {path} (matched {count} times)")
    open(full, "w").write(patched)
    print(f"  patched {path}")
PY

XCODE="$WORK/love/platform/xcode"
mv "$WORK/deps/iOS/libraries" "$XCODE/ios/libraries"
mv "$WORK/deps/shared" "$XCODE/shared"

# Build the love-ios app target the same way LÖVE's CI does; it pulls in
# liblove-ios (the static library we actually want) and proves it links.
echo "Building love-ios (Release, iphoneos)"
BUILD_LOG="$WORK/xcodebuild.log"
set +e
xcodebuild \
  -project "$XCODE/love.xcodeproj" \
  -scheme love-ios \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$WORK/dd" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build > "$BUILD_LOG" 2>&1
status=$?
set -e
if [ $status -ne 0 ]; then
  echo "::error::LÖVE build failed (exit $status). Errors:"
  grep -E "error:|\*\* BUILD FAILED" "$BUILD_LOG" | head -60 || true
  echo "--- last 80 lines ---"
  tail -80 "$BUILD_LOG"
  exit $status
fi

LIBLOVE="$(find "$WORK/dd/Build/Products" -name liblove.a -path '*iphoneos*' | head -1)"
[ -n "$LIBLOVE" ] || { echo "::error::liblove.a not found"; exit 1; }

echo "Staging into $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include/common" "$OUT/include/modules/love" "$OUT/Frameworks"
cp "$LIBLOVE" "$OUT/lib/liblove.a"
cp "$WORK/love/src/common/config.h" "$OUT/include/common/"
cp "$WORK/love/src/modules/love/love.h" "$OUT/include/modules/love/"
for fw in Lua freetype harfbuzz modplug ogg theora vorbis; do
  cp -R "$XCODE/ios/libraries/$fw.xcframework" "$OUT/Frameworks/"
done
cp -R "$XCODE/shared/Frameworks/SDL3.xcframework" "$OUT/Frameworks/"
echo "$LOVE_SHA" > "$OUT/LOVE_SHA"

du -sh "$OUT"/* | sed 's#'"$OUT"'/##'
rm -rf "$WORK"
