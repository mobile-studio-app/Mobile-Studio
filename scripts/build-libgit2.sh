#!/usr/bin/env bash
# Builds libgit2 (the app's git: real repositories, history, fetch, push and merge over HTTPS)
# as static libraries: for iOS (the app) and for this Mac (the git tests CI runs before the app
# builds). HTTPS uses Apple's SecureTransport and SHA-256 CommonCrypto, so nothing else is needed.
#
# Output, in third_party/libgit2:
#   include/        git2.h and git2/, with a module map: `import Clibgit2` in Swift
#   ios/libgit2.a   arm64 iPhone and iPad
#   macos/libgit2.a this Mac's architecture, for Tests/GitEngine
#
# usage: scripts/build-libgit2.sh
set -euo pipefail

VERSION=1.9.7
SHA256=1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/third_party/libgit2"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/libgit2.tar.gz" "https://github.com/libgit2/libgit2/archive/refs/tags/v$VERSION.tar.gz"
echo "$SHA256  $WORK/libgit2.tar.gz" | shasum -a 256 -c -
tar xzf "$WORK/libgit2.tar.gz" -C "$WORK"
SRC="$WORK/libgit2-$VERSION"

COMMON=(
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DBUILD_EXAMPLES=OFF
  -DUSE_HTTPS=SecureTransport -DUSE_SHA1=CollisionDetection -DUSE_SHA256=HTTPS
  -DUSE_SSH=OFF -DUSE_GSSAPI=OFF -DUSE_NTLMCLIENT=OFF -DUSE_ICONV=OFF
  -DREGEX_BACKEND=builtin -DUSE_HTTP_PARSER=builtin -DUSE_BUNDLED_ZLIB=ON
  # Cross-compiling for iOS: feature checks compile, they don't link and run.
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
)

build() {   # build <name> <cmake args...>
  local name=$1; shift
  cmake -S "$SRC" -B "$WORK/build-$name" "${COMMON[@]}" "$@" -DCMAKE_INSTALL_PREFIX="$WORK/install-$name" > "$WORK/$name.log" \
    || { tail -40 "$WORK/$name.log"; exit 1; }
  cmake --build "$WORK/build-$name" --config Release -j "$(sysctl -n hw.ncpu)" > "$WORK/$name-build.log" \
    || { tail -60 "$WORK/$name-build.log"; exit 1; }
  cmake --install "$WORK/build-$name" > /dev/null
}

build ios -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0
build macos -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0

rm -rf "$OUT"
mkdir -p "$OUT/ios" "$OUT/macos"
cp "$WORK/install-ios/lib/libgit2.a" "$OUT/ios/"
cp "$WORK/install-macos/lib/libgit2.a" "$OUT/macos/"
cp -R "$WORK/install-ios/include" "$OUT/include"
# Swift can't call C's variadic functions, so libgit2's global options get plain wrappers.
cat > "$OUT/include/ms_git.h" <<'EOF'
#include "git2.h"
#include "git2/sys/errors.h"

static inline int ms_git_set_owner_validation(int enabled) {
    return git_libgit2_opts(GIT_OPT_SET_OWNER_VALIDATION, enabled);
}

static inline int ms_git_set_global_config_path(const char *path) {
    return git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH, GIT_CONFIG_LEVEL_GLOBAL, path);
}
EOF
cat > "$OUT/include/module.modulemap" <<'EOF'
module Clibgit2 {
    header "git2.h"
    header "ms_git.h"
    link "git2"
    link "z"
    link framework "Security"
    link framework "CoreFoundation"
    export *
}
EOF
echo "$VERSION" > "$OUT/LIBGIT2_VERSION"
ls -la "$OUT/ios" "$OUT/macos"
