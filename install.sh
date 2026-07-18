#!/bin/bash
set -euo pipefail

APP="InputSourceSwitcher.app"
DEST="/Applications"

# ビルド済みか確認
if [ ! -d "$APP" ]; then
    echo "エラー: $APP が見つかりません。先に ./build.sh を実行してください。"
    exit 1
fi

# 配置先に書き込めるか確認
if [ ! -w "$DEST" ]; then
    echo "エラー: $DEST に書き込み権限がありません。sudo で実行し直してください:"
    echo "    sudo ./install.sh"
    exit 1
fi

# 動作中なら先に終了（実行中バイナリの上書きを避ける）
if pgrep -x "InputSourceSwitcher" >/dev/null 2>&1; then
    echo "==> 動作中の InputSourceSwitcher を終了します"
    osascript -e 'quit app "InputSourceSwitcher"' 2>/dev/null \
        || killall InputSourceSwitcher 2>/dev/null || true
    sleep 1
fi

# 既存を置き換え
if [ -d "$DEST/$APP" ]; then
    echo "==> 既存の $DEST/$APP を置き換えます"
    rm -rf "$DEST/$APP"
fi

echo "==> $DEST へコピー"
cp -R "$APP" "$DEST/"

# quarantine 属性を除去（AirDrop/ダウンロード由来の場合。自ビルドなら通常は無し）
echo "==> quarantine 属性を除去（あれば）"
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

echo ""
echo "完了: $DEST/$APP"
echo ""
echo "次の手順:"
echo "  1. 起動: open \"$DEST/$APP\"  （またはFinderでダブルクリック）"
echo "  2. アクセシビリティを許可"
echo "     システム設定 > プライバシーとセキュリティ > アクセシビリティ"
echo "  3. いったん終了して、もう一度起動（初回のみ・権限反映のため）"
