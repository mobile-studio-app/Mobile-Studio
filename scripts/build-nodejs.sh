#!/usr/bin/env bash
# Links Node.js for iOS with ICU (static libraries from scripts/compile-nodejs.sh, in
# third_party/nodejs-libs) into third_party/nodejs-mobile/NodeMobile.xcframework, for the
# Node.js extension host (App/Extensions/NodeExtensionHost.swift). The framework bundle
# (Info.plist, headers) comes from nodejs-mobile's official release; only its binary is
# replaced.
#
# usage: scripts/build-nodejs.sh
set -euo pipefail

TAG=v18.20.4
ASSET=nodejs-mobile-v18.20.4-ios.zip
SHA256=8c5ca3a0d1e38de7f182a5642593e82593b820efd375a14b3ecafc4bcfee620e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/third_party/nodejs-mobile"
LIBS_DIR="$ROOT/third_party/nodejs-libs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[ -d "$LIBS_DIR" ] || { echo "Run scripts/compile-nodejs.sh first."; exit 1; }

# The official framework bundle, for its Info.plist and headers.
curl -fsSL -o "$WORK/node.zip" "https://github.com/nodejs-mobile/nodejs-mobile/releases/download/$TAG/$ASSET"
echo "$SHA256  $WORK/node.zip" | shasum -a 256 -c -
mkdir -p "$WORK/release"
unzip -q "$WORK/node.zip" -d "$WORK/release"

# The iOS libraries (ICU's build tools are built for the Mac too; they're left out, as is
# ICU's empty stand-in for its data). Output goes to a file before grep: grep -q stops
# reading early, and with pipefail the writer's broken pipe would count as no match.
LIBS=()
for archive in "$LIBS_DIR"/*.a; do
  case "$(basename "$archive")" in libgtest*|libicustubdata.a) continue ;; esac
  otool -l "$archive" > "$WORK/commands.txt" 2>/dev/null || true
  if grep -qE "platform (2|IOS)$|LC_VERSION_MIN_IPHONEOS" "$WORK/commands.txt"; then
    LIBS+=("$archive")
  else
    echo "Not for iOS, left out: $archive"
  fi
done
printf 'Linking %s\n' "${LIBS[@]}"

cat > "$WORK/NodeMobile.cpp" <<'EOF'
// As nodejs-mobile's tools/ios-framework/NodeMobile/NodeMobile.cpp.
namespace node {
int Start(int argc, char *argv[]);
}  // namespace node

extern "C" __attribute__((visibility("default"))) int node_start(int argc, char *argv[]) {
    return node::Start(argc, argv);
}
EOF

# ICU's data. With small-icu it's generated as icusmdt74_dat, while ICU's code looks for
# icudt74_dat: load it whole and give it that name too.
nm -U "$LIBS_DIR/libicudata.a" > "$WORK/icudata.txt" 2>/dev/null || true
DATA_SYMBOL="$(grep -m1 -oE "_icu[a-z]*dt[0-9]+_dat" "$WORK/icudata.txt" || true)"
[ -n "$DATA_SYMBOL" ] || { echo "libicudata.a has no data symbol"; exit 1; }
echo "ICU data: $DATA_SYMBOL"
DATA_FLAGS=(-Wl,-force_load,"$LIBS_DIR/libicudata.a")
if [ "$DATA_SYMBOL" != "_icudt74_dat" ]; then DATA_FLAGS+=(-Wl,-alias,"$DATA_SYMBOL",_icudt74_dat); fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun -sdk iphoneos clang++ -arch arm64 -isysroot "$SDK" -miphoneos-version-min=13.0 -std=c++17 -O2 \
  -dynamiclib -install_name @rpath/NodeMobile.framework/NodeMobile \
  -o "$WORK/NodeMobile" "$WORK/NodeMobile.cpp" "${DATA_FLAGS[@]}" "${LIBS[@]}" \
  -framework CoreFoundation -lc++ -Wl,-dead_strip
# ICU's data really is in (not a stand-in), before stripping hides the name.
nm -U "$WORK/NodeMobile" > "$WORK/symbols.txt"
grep -q "_icudt74_dat" "$WORK/symbols.txt" || { echo "ICU's data isn't linked in"; exit 1; }
strip -x "$WORK/NodeMobile"

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$WORK/release/NodeMobile.xcframework" "$OUT/"
# Only the device slice; the simulator slice isn't used.
rm -rf "$OUT/NodeMobile.xcframework/ios-arm64_x86_64-simulator"
/usr/libexec/PlistBuddy -c "Delete :AvailableLibraries:1" "$OUT/NodeMobile.xcframework/Info.plist" 2>/dev/null || true
BIN="$OUT/NodeMobile.xcframework/ios-arm64/NodeMobile.framework/NodeMobile"
cp "$WORK/NodeMobile" "$BIN"

# iOS 27's dyld refuses zero-fill sections with a file offset (see patch-zerofill-offsets.py).
codesign --remove-signature "$BIN" 2>/dev/null || true
python3 "$ROOT/scripts/patch-zerofill-offsets.py" "$BIN"

nm -gU "$BIN" > "$WORK/exports.txt"
grep -q "_node_start" "$WORK/exports.txt" || { echo "node_start isn't exported"; exit 1; }
ls -la "$BIN"
