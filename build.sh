#!/bin/bash
set -euo pipefail

# All variable expansions use ${...} braces.
# 変数展開はすべて ${...} と波括弧で囲む。
#   macOS's stock bash 3.2 can absorb a following multi-byte character into
#   the variable name under a UTF-8 locale.
#   bash 3.2 は UTF-8 ロケール下で $VAR の直後の全角文字を変数名に取り込むため。

APP="InputSourceSwitcher.app"
BIN="InputSourceSwitcher"

echo "==> Compiling / コンパイル"
swiftc -O main.swift -o "${BIN}" \
    -framework Cocoa -framework Carbon -framework ServiceManagement

echo "==> Preparing app icon / アプリアイコンを準備"
# Generate AppIcon.icns from the iconset if it is missing (iconutil ships with macOS).
# AppIcon.icns が無ければ AppIcon.iconset から生成（iconutil は macOS 標準）。
if [ ! -f AppIcon.icns ]; then
    if command -v iconutil >/dev/null 2>&1 && [ -d AppIcon.iconset ]; then
        iconutil -c icns AppIcon.iconset -o AppIcon.icns
    else
        echo "    WARNING: no AppIcon.icns and no iconutil - building without an icon."
        echo "    警告: AppIcon.icns も iconutil も無いため、アイコン無しでビルドします。"
    fi
fi

echo "==> Assembling app bundle / アプリバンドルを構成"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"
cp Info.plist "${APP}/Contents/Info.plist"
cp "${BIN}" "${APP}/Contents/MacOS/${BIN}"
rm -f "${BIN}"
# Use if, not "[ -f ... ] && cp ...": under set -e a false test aborts the script.
# if を使う。"[ -f ... ] && cp ..." だと set -e 下でテストが偽のとき全体が中断する。
if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
fi

echo "==> Ad-hoc code signing / アドホック署名"
codesign --force --sign - "${APP}"
codesign --verify --verbose "${APP}"

echo ""
echo "Built: ${APP}"
echo "ビルド完了: ${APP}"
echo ""
echo "Try it   / 試す:   open ./${APP}"
echo "Install  / 配置:   ./install.sh"
echo ""
echo "On first launch, grant Accessibility - it takes effect without a restart."
echo "初回起動時にアクセシビリティを許可してください。再起動は不要です。"
