#!/bin/bash
set -euo pipefail

APP="InputSourceSwitcher.app"
BIN="InputSourceSwitcher"

echo "==> compiling"
swiftc -O main.swift -o "$BIN" \
    -framework Cocoa -framework Carbon -framework ServiceManagement

echo "==> preparing app icon"
# AppIcon.icns が無ければ AppIcon.iconset から生成（iconutil は macOS 標準）
if [ ! -f AppIcon.icns ]; then
    if command -v iconutil >/dev/null 2>&1 && [ -d AppIcon.iconset ]; then
        iconutil -c icns AppIcon.iconset -o AppIcon.icns
    else
        echo "   警告: AppIcon.icns も iconutil も無いため、アイコン無しでビルドします"
    fi
fi

echo "==> assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/$BIN"
rm -f "$BIN"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc code signing"
codesign --force --sign - "$APP"
codesign --verify --verbose "$APP"

echo "==> done: $APP"
echo "起動:  open ./$APP   （初回はアクセシビリティ許可 → 許可すれば再起動不要で有効）"
echo "配置:  ./install.sh"
