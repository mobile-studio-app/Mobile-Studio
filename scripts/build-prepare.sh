#!/usr/bin/env bash
# Builds NativeTools/prepare (the Rust library that rewrites and signs extensions' macOS
# programs) for iOS, into third_party/prepare/libduocode_prepare.a.
set -euo pipefail
cd "$(dirname "$0")/.."
rustup target add aarch64-apple-ios
export IPHONEOS_DEPLOYMENT_TARGET=17.0
(cd NativeTools/prepare && cargo build --release --locked --lib --target aarch64-apple-ios)
mkdir -p third_party/prepare
cp NativeTools/prepare/target/aarch64-apple-ios/release/libduocode_prepare.a third_party/prepare/
ls -la third_party/prepare
