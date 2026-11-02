#!/usr/bin/env bash
# Xcode build phase for the app: copies Python's standard library into the bundle and wraps each
# binary extension module as a framework, the only form iOS loads native code from in an app.
# Adapted from BeeWare's Python.xcframework/build/utils.sh, minus code signing: the IPA is signed
# when it's sideloaded. Leaves out parts that can't be used on a phone (tests, IDLE, tkinter, pip).
set -euo pipefail

XCF="$PROJECT_DIR/third_party/python/Python.xcframework"
if [ ! -d "$XCF" ]; then
  echo "warning: $XCF is missing (run scripts/fetch-python.sh); the Python interpreter won't work"
  exit 0
fi

DEST="$CODESIGNING_FOLDER_PATH/python/lib"
mkdir -p "$DEST"
rsync -a --delete "$XCF/lib/" "$DEST/" \
  --exclude 'libpython*.dylib' --exclude '__pycache__/' \
  --exclude 'test/' --exclude 'tests/' --exclude 'idlelib/' --exclude 'tkinter/' \
  --exclude 'turtledemo/' --exclude 'ensurepip/' --exclude 'pydoc_data/'
rsync -a "$XCF/ios-arm64/lib-arm64/" "$DEST/" --exclude 'libpython*.dylib'

PY_VER="$(ls -1 "$DEST" | grep -E '^python3\.[0-9]+$')"
DYNLOAD="python/lib/$PY_VER/lib-dynload"
TEMPLATE="$XCF/build/iOS-dylib-Info-template.plist"

find "$CODESIGNING_FOLDER_PATH/$DYNLOAD" -name "*.so" | while read -r FULL_EXT; do
  RELATIVE_EXT="${FULL_EXT#$CODESIGNING_FOLDER_PATH/}"
  MODULE="$(basename "$FULL_EXT" | cut -d "." -f 1)"
  FRAMEWORK="Frameworks/$MODULE.framework"
  mkdir -p "$CODESIGNING_FOLDER_PATH/$FRAMEWORK"
  cp "$TEMPLATE" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK/Info.plist"
  plutil -replace CFBundleExecutable -string "$MODULE" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK/Info.plist"
  plutil -replace CFBundleIdentifier -string "$(echo "$PRODUCT_BUNDLE_IDENTIFIER.$MODULE" | tr "_" "-")" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK/Info.plist"
  mv "$FULL_EXT" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK/$MODULE"
  # Python finds the module through this placeholder; the framework points back at it.
  echo "$FRAMEWORK/$MODULE" > "${FULL_EXT%.so}.fwork"
  echo "${RELATIVE_EXT%.so}.fwork" > "$CODESIGNING_FOLDER_PATH/$FRAMEWORK/$MODULE.origin"
done
# pip (scripts/fetch-python.sh): imported from its wheel.
[ -f "$PROJECT_DIR/third_party/python/pip.whl" ] && cp "$PROJECT_DIR/third_party/python/pip.whl" "$CODESIGNING_FOLDER_PATH/python/pip.whl"
echo "Installed Python $PY_VER standard library into python/lib"
