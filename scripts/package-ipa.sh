#!/usr/bin/env bash
# Package an unsigned-build .app into a sideloadable .ipa.
# Stamps the binary and frameworks with iOS 27.2 SDK load commands (via vtool)
# to break out of iPhone Duo letterbox compatibility mode, then ad-hoc signs.
#
# usage: scripts/package-ipa.sh <path/to/DuoCode.app> <out.ipa>
set -euo pipefail

APP="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENT="$ROOT/App/DuoCode.entitlements"

[ -d "$APP" ] || { echo "No app at $APP"; exit 1; }

WORK="$(mktemp -d)"
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
APPDIR="$WORK/Payload/$(basename "$APP")"

# Strip anything that confuses sideloaders.
find "$APPDIR" -name "_CodeSignature" -type d -prune -exec rm -rf {} +
rm -f "$APPDIR/embedded.mobileprovision"

# --- Stamp Mach-O binaries with iOS 27.2 SDK to disable letterbox compatibility mode ---
stamp_macho_sdk() {
  local target="$1"
  if [ -f "$target" ]; then
    echo "Stamping $target with iOS 27.2 SDK via xcrun vtool..."
    if xcrun vtool -set-build-version ios 17.0 27.2 -output "${target}.stamped" "$target" 2>/dev/null; then
      mv "${target}.stamped" "$target"
      chmod +x "$target"
    fi
  fi
}

APP_BIN="$APPDIR/$(basename "$APP" .app)"
stamp_macho_sdk "$APP_BIN"

if [ -d "$APPDIR/Frameworks" ]; then
  for fw in "$APPDIR"/Frameworks/*.framework; do
    [ -d "$fw" ] || continue
    fw_bin="$fw/$(basename "$fw" .framework)"
    stamp_macho_sdk "$fw_bin"
  done
fi

# Stamp Info.plist with iOS 27.2 SDK identifiers
if [ -f "$APPDIR/Info.plist" ]; then
  /usr/libexec/PlistBuddy -c "Set :DTSDKName iphoneos27.2" "$APPDIR/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :DTSDKName string iphoneos27.2" "$APPDIR/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :DTPlatformVersion 27.2" "$APPDIR/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :DTPlatformVersion string 27.2" "$APPDIR/Info.plist" 2>/dev/null || true
fi

# Ad-hoc sign inner frameworks first, then the app with entitlements.
if [ -d "$APPDIR/Frameworks" ]; then
  for fw in "$APPDIR"/Frameworks/*.framework "$APPDIR"/Frameworks/*.dylib; do
    [ -e "$fw" ] || continue
    codesign --force --sign - --timestamp=none "$fw"
  done
fi
codesign --force --sign - --timestamp=none --entitlements "$ENT" "$APPDIR"
codesign -d --entitlements - "$APPDIR" || true

mkdir -p "$(dirname "$OUT")"
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT_ABS"
(cd "$WORK" && zip -qry "$OUT_ABS" Payload)
rm -rf "$WORK"
echo "Wrote $OUT_ABS ($(du -h "$OUT_ABS" | cut -f1))"
