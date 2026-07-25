#!/bin/bash
set -euo pipefail

# All variable expansions use ${...} braces.
# 変数展開はすべて ${...} と波括弧で囲む。
#   macOS's stock bash 3.2 can absorb the following multi-byte character into
#   the variable name under a UTF-8 locale, causing "unbound variable".
#   bash 3.2 は UTF-8 ロケール下で $VAR の直後の全角文字を変数名に取り込み、
#   "unbound variable" で落ちることがあるため。

APP="InputSourceSwitcher.app"
DEST="/Applications"

# Run permission-related commands as the real user even under sudo.
# sudo 実行時も権限まわりは元のユーザーとして実行する。
#   TCC is per-user, so tccutil run as root silently fails to clear the entry.
#   TCC はユーザー単位のため、root で実行しても登録は消えず、エラーも出ない。
as_user() {
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        sudo -u "${SUDO_USER}" "$@"
    else
        "$@"
    fi
}

# --- Check the build / ビルド済みか確認 ---
if [ ! -d "${APP}" ]; then
    echo "ERROR: ${APP} not found. Run ./build.sh first."
    echo "エラー: ${APP} がありません。先に ./build.sh を実行してください。"
    exit 1
fi

# --- Check write access / 書き込み権限を確認 ---
if [ ! -w "${DEST}" ]; then
    echo "ERROR: ${DEST} is not writable. Re-run with: sudo ./install.sh"
    echo "エラー: ${DEST} に書き込めません。sudo ./install.sh で再実行してください。"
    exit 1
fi

# --- Read the bundle ID from Info.plist / バンドルIDを Info.plist から取得 ---
#   Never hard-code it: an empty value passed to tccutil would reset every app.
#   ハードコードしない。空のまま tccutil に渡すと全アプリの許可が消えるため。
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "${APP}/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "${BUNDLE_ID}" ]; then
    echo "ERROR: could not read the bundle ID. Aborting."
    echo "エラー: バンドルIDを取得できません。処理を中止します。"
    exit 1
fi

IS_UPDATE=0
[ -d "${DEST}/${APP}" ] && IS_UPDATE=1

# --- Quit a running instance / 動作中なら終了 ---
#   -x matches by process name, so a copy launched from the build directory
#   is caught too. -x で名前を見るため、ビルド先から起動した分も捕まえる。
if pgrep -x "InputSourceSwitcher" >/dev/null 2>&1; then
    echo "==> Quitting running instance / 起動中のインスタンスを終了"
    as_user osascript -e 'quit app "InputSourceSwitcher"' 2>/dev/null \
        || killall InputSourceSwitcher 2>/dev/null || true
    sleep 1
fi

# --- Reset the stale Accessibility registration / 古い権限登録をリセット ---
#   Ad-hoc signing changes the signature hash on every build, so the old grant
#   stops working while the entry stays in the list with its checkbox on.
#   アドホック署名はビルドごとに署名が変わるため許可が無効化されるが、
#   一覧にはチェックが入ったまま残り、有効なように見えてしまう。
echo "==> Resetting Accessibility entry / アクセシビリティ登録をリセット: ${BUNDLE_ID}"
if as_user tccutil reset Accessibility "${BUNDLE_ID}" >/dev/null 2>&1; then
    echo "    Done. You will be asked to grant it again on next launch."
    echo "    完了。次回起動時にあらためて許可を求めます。"
elif [ "${IS_UPDATE}" -eq 1 ]; then
    echo "    Failed. If the app does not work, fix it manually:"
    echo "    失敗しました。動かない場合は手動で対応してください:"
    echo "      System Settings > Privacy & Security > Accessibility"
    echo "      システム設定 > プライバシーとセキュリティ > アクセシビリティ"
    echo "      Remove the entry with the minus button, then add it again."
    echo "      一覧から「−」で削除してから、あらためて追加してください。"
    echo "      (Unchecking and re-checking does NOT work / チェックの付け直しでは直りません)"
else
    echo "    No entry found - normal for a first install."
    echo "    登録なし。初回インストールでは正常です。"
fi

# --- Replace / 置き換え ---
if [ "${IS_UPDATE}" -eq 1 ]; then
    echo "==> Replacing existing app / 既存アプリを置き換え"
    rm -rf "${DEST}/${APP}"
fi

echo "==> Copying to ${DEST} / ${DEST} へコピー"
cp -R "${APP}" "${DEST}/"

# --- Clear the quarantine flag / quarantine 属性を除去 ---
#   Only set when the app arrived via download or AirDrop.
#   ダウンロードや AirDrop 経由の場合のみ付く属性。
echo "==> Clearing quarantine flag / quarantine 属性を除去"
xattr -dr com.apple.quarantine "${DEST}/${APP}" 2>/dev/null || true

echo ""
echo "Installed: ${DEST}/${APP}"
echo "インストール完了: ${DEST}/${APP}"
echo ""
echo "Next steps / 次の手順:"
echo "  1. Launch it:  open \"${DEST}/${APP}\""
echo "                 or double-click it in the Applications folder."
echo "     起動:       open \"${DEST}/${APP}\""
echo "                 または「アプリケーション」フォルダでダブルクリック。"
echo "  2. Grant Accessibility when prompted."
echo "     アクセシビリティを許可してください。"
echo "     System Settings > Privacy & Security > Accessibility"
echo "     システム設定 > プライバシーとセキュリティ > アクセシビリティ"
echo "     It becomes active in a second or two - no restart needed."
echo "     1〜2秒で有効になります。再起動は不要です。"
echo ""
echo "Your settings are preserved across updates."
echo "設定は更新後も引き継がれます。"
echo ""
echo "Logs / ログ:"
echo "  log show --predicate 'subsystem == \"${BUNDLE_ID}\"' --last 1h --info --debug"
