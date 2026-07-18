#!/bin/bash
set -euo pipefail

APP="InputSourceSwitcher.app"
BIN="InputSourceSwitcher"

echo "==> compiling"
swiftc -O main.swift -o "$BIN" \
    -framework Cocoa -framework Carbon -framework ServiceManagement

echo "==> assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/$BIN"
rm -f "$BIN"

echo "==> code signing (ad-hoc)"
codesign --force --sign - "$APP"
codesign --verify --verbose "$APP"

echo "==> done: $APP"
echo "起動:  open ./$APP   （初回はアクセシビリティ許可 → 一度終了 → 再起動）"
echo "配置例:  cp -r ./$APP /Applications/"
