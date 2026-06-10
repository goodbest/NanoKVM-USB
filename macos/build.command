#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
ARCH="${ARCH:-arm64}"
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-12.0}"
TARGET="${ARCH}-apple-macosx${MACOS_DEPLOYMENT_TARGET}"

echo "Building NanoKVM for ${TARGET}..."
clang -c FrameRateGuard.m \
  -o FrameRateGuard.o \
  -target "${TARGET}" \
  -fobjc-arc
swiftc NanoKVM.swift FrameRateGuard.o \
  -o NanoKVM_bin \
  -target "${TARGET}" \
  -import-objc-header NanoKVM-Bridging-Header.h \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework AudioToolbox \
  -framework VideoToolbox \
  -framework UniformTypeIdentifiers \
  -framework Metal \
  -O
rm -f FrameRateGuard.o
echo Creating app bundle...
rm -rf NanoKVM.app
mkdir -p NanoKVM.app/Contents/MacOS
mv NanoKVM_bin NanoKVM.app/Contents/MacOS/NanoKVM
mkdir -p NanoKVM.app/Contents/Resources
cp Info.plist NanoKVM.app/Contents/Info.plist
cp AppIcon.icns NanoKVM.app/Contents/Resources/AppIcon.icns
if command -v codesign >/dev/null 2>&1; then
  echo Signing NanoKVM.app with an ad-hoc identity...
  codesign --force --deep --sign - NanoKVM.app
fi
echo Done. NanoKVM.app is ready.
echo Double-click NanoKVM.app to run.
