import Cocoa
import Carbon.HIToolbox
import ServiceManagement
import os

// ═══════════════════════════════════════════════════════
//  設定の保存キー
// ═══════════════════════════════════════════════════════
enum Keys {
    static let enabled = "enabled"
    static let requiredFlags = "requiredFlags"
    static let followupCount = "followupCount"
    static let toggleSources = "toggleSources"   // 決め打ちする2ソースのID
}

// 横取りするキー（49 = スペース固定。変えたい場合はここを編集）
let switchKeyCode: CGKeyCode = 49
// 修飾キーの判定に使う主要マスク
let majorMask: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
// 二段撃ちの間隔
let followupDelayMs: Int = 60

// UI言語: システムの優先言語が日本語なら日本語、それ以外は英語
let uiLang: String = {
    let pref = Locale.preferredLanguages.first ?? "en"
    return pref.hasPrefix("ja") ? "ja" : "en"
}()
// 対訳を選ぶ。L("日本語", "English")
func L(_ ja: String, _ en: String) -> String {
    return uiLang == "ja" ? ja : en
}

// ═══════════════════════════════════════════════════════
//  ログ（OS標準の統合ログ）
// ═══════════════════════════════════════════════════════
// 独自ファイルには書かない。理由は2つ:
//  1. イベントタップのコールバック内でファイルI/Oを行うと処理が遅れ、
//     OSにタップを無効化される（tapDisabledByTimeout）原因になる。
//  2. os.Logger は収集対象でないレベルの文字列組み立て自体をスキップするため、
//     通常運用のコストがほぼゼロになる。
//
// 確認方法:
//   log show --predicate 'subsystem == "com.naito.InputSourceSwitcher2"' \
//            --last 1h --info --debug
//   log stream --predicate 'subsystem == "com.naito.InputSourceSwitcher2"' --level debug
// GUI なら「コンソール.app」で subsystem:com.naito.InputSourceSwitcher2 を検索。
//
// 注意: os.Logger は変数を既定で伏せ字にするため、値は privacy: .public を明示する。
let subsystemID = Bundle.main.bundleIdentifier ?? "com.naito.InputSourceSwitcher2"
let logger = Logger(subsystem: subsystemID, category: "main")

// ═══════════════════════════════════════════════════════
//  TIS ヘルパー
// ═══════════════════════════════════════════════════════
func stringProperty(_ src: TISInputSource, _ key: CFString) -> String? {
    guard let p = TISGetInputSourceProperty(src, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}
func boolProperty(_ src: TISInputSource, _ key: CFString) -> Bool {
    guard let p = TISGetInputSourceProperty(src, key) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
}
func selectableKeyboardSources() -> [TISInputSource] {
    guard let cf = TISCreateInputSourceList(nil, false)?.takeRetainedValue(),
          let list = cf as? [TISInputSource] else { return [] }
    let kb = kTISCategoryKeyboardInputSource as String
    return list.filter {
        stringProperty($0, kTISPropertyInputSourceCategory) == kb
            && boolProperty($0, kTISPropertyInputSourceIsSelectCapable)
            && boolProperty($0, kTISPropertyInputSourceIsEnabled)
    }
}
func currentSourceID() -> String? {
    guard let s = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
    return stringProperty(s, kTISPropertyInputSourceID)
}
func source(forID id: String) -> TISInputSource? {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let cf = TISCreateInputSourceList(filter, false)?.takeRetainedValue(),
          let list = cf as? [TISInputSource] else { return nil }
    return list.first
}
// 表示用の読みやすい名前（例: "ひらがな", "ABC"）。取れなければID。
func localizedName(_ src: TISInputSource) -> String {
    return stringProperty(src, kTISPropertyLocalizedName)
        ?? stringProperty(src, kTISPropertyInputSourceID)
        ?? "?"
}
func nameForID(_ id: String) -> String {
    if let s = source(forID: id) { return localizedName(s) }
    return id
}

// ═══════════════════════════════════════════════════════
//  イベントタップのコールバック（C関数ポインタ）
// ═══════════════════════════════════════════════════════
let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let ctrl = Unmanaged<Controller>.fromOpaque(refcon).takeUnretainedValue()
    return ctrl.handle(type: type, event: event)
}

// ═══════════════════════════════════════════════════════
//  コントローラ本体（アプリデリゲート兼用）
// ═══════════════════════════════════════════════════════
final class Controller: NSObject, NSApplicationDelegate {
    let defaults = UserDefaults.standard
    var statusItem: NSStatusItem!
    var tap: CFMachPort?

    var enabled = true
    var requiredFlags: CGEventFlags = [.maskControl]
    var followupCount = 2
    var toggleSources: [String] = []   // 0個=自動モード / 2個=決め打ちトグル

    var currentID: String?
    var previousID: String?

    // keyDown を飲み込んだら、対応する keyUp も飲み込むためのフラグ。
    // keyUp を素通しすると、キー状態を自前で追跡するアプリが
    // 「押しっぱなし」と誤認することがある。
    var swallowedKeyDown = false

    var permissionTimer: Timer?        // 権限付与を待つ監視タイマー
    var permissionElapsed = 0
    var permissionHintShown = false

    // ── 起動 ──────────────────────────────────────────
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 多重起動を防ぐ。2つ動くと両方が切替を実行して往復し、
        // 見た目上「切り替わらない」状態になる。
        if terminateIfAlreadyRunning() { return }

        loadSettings()

        let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(axOpts)
        logger.notice("launched; accessibility trusted = \(trusted, privacy: .public)")

        currentID = currentSourceID()

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in self?.onSelectionChanged() }

        setupStatusItem()
        installTap()
        applyEnabledState()
        rebuildMenu()

        // タップ未設置（＝権限未付与）なら、付与を監視して自動でタップを設置する
        if tap == nil {
            logger.notice("accessibility not granted yet; watching for permission")
            startPermissionWatch()
        }
    }

    // 同じバンドルIDの別プロセスが動いていれば、こちらを終了する
    func terminateIfAlreadyRunning() -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: subsystemID)
            .filter { $0.processIdentifier != myPID }
        guard !others.isEmpty else { return false }

        logger.error("another instance is already running; terminating this one")
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("InputSourceSwitcher はすでに起動しています。",
                          "InputSourceSwitcher is already running.")
        a.informativeText = L("メニューバーのアイコンから操作してください。",
                              "Use the existing menu-bar icon.")
        a.runModal()
        NSApp.terminate(nil)
        return true
    }

    // 権限が付くまで定期的に確認し、付いたらタップを設置してメニューへ即反映する。
    // 通常起動（既に許可済み）ではタイマーは動かない。
    func startPermissionWatch() {
        permissionTimer?.invalidate()
        permissionElapsed = 0
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            self.permissionElapsed += 1

            guard AXIsProcessTrusted() else {
                // 一覧に古いエントリが残っていると、チェックが入っていても
                // 権限は付かない。しばらく待っても付かない場合に案内する。
                if self.permissionElapsed >= 30 && !self.permissionHintShown {
                    self.permissionHintShown = true
                    self.showStalePermissionHint()
                }
                return
            }
            self.installTap()
            if self.tap != nil {
                self.applyEnabledState()
                self.rebuildMenu()
                logger.notice("permission granted; tap installed without restart")
                t.invalidate()
                self.permissionTimer = nil
            }
        }
    }

    // アドホック署名のため、更新後は一覧に残ったエントリが無効になっている。
    // チェックの付け直しでは直らず、削除→再追加が必要。
    func showStalePermissionHint() {
        logger.error("accessibility still not granted after 30s; showing stale-entry hint")
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = L("アクセシビリティの許可がまだ有効になっていません。",
                          "Accessibility permission is still not active.")
        a.informativeText = L(
            "一覧に InputSourceSwitcher が表示され、チェックが入っていても動かない場合は、"
            + "古い登録が残っています。\n\n"
            + "「−」ボタンで一覧から削除してから、あらためて追加してください。\n"
            + "チェックを外して入れ直すだけでは直りません。",
            "If InputSourceSwitcher already appears in the list with its checkbox on but "
            + "still does not work, a stale entry is left over.\n\n"
            + "Remove it from the list with the “−” button, then add it again.\n"
            + "Unchecking and re-checking the box will not fix it.")
        a.addButton(withTitle: L("アクセシビリティ設定を開く", "Open Accessibility settings"))
        a.addButton(withTitle: L("閉じる", "Close"))
        if a.runModal() == .alertFirstButtonReturn { openAX() }
    }

    // ── 設定の読み書き ────────────────────────────────
    func loadSettings() {
        if defaults.object(forKey: Keys.enabled) != nil {
            enabled = defaults.bool(forKey: Keys.enabled)
        }
        if let n = defaults.object(forKey: Keys.requiredFlags) as? NSNumber {
            let restored = CGEventFlags(rawValue: n.uint64Value).intersection(majorMask)
            // 修飾キーが空だと素のスペースに一致してしまうため、念のため補正する
            requiredFlags = restored.isEmpty ? [.maskControl] : restored
        }
        if let n = defaults.object(forKey: Keys.followupCount) as? NSNumber {
            followupCount = max(0, n.intValue)
        }
        if let arr = defaults.stringArray(forKey: Keys.toggleSources) {
            toggleSources = arr
        }
    }
    func saveSettings() {
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(NSNumber(value: requiredFlags.rawValue), forKey: Keys.requiredFlags)
        defaults.set(NSNumber(value: followupCount), forKey: Keys.followupCount)
        defaults.set(toggleSources, forKey: Keys.toggleSources)
    }

    // ── メニューバー ──────────────────────────────────
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "InputSourceSwitcher")
            btn.image?.isTemplate = true
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()

        let enItem = NSMenuItem(title: L("有効", "Enabled"), action: #selector(toggleEnabled), keyEquivalent: "")
        enItem.target = self
        enItem.state = enabled ? .on : .off
        menu.addItem(enItem)

        menu.addItem(.separator())

        // ── トグル対象のソース選択 ──
        let modeInfo: String
        if toggleSources.count == 2 {
            modeInfo = L("トグル: ", "Toggle: ") + "\(nameForID(toggleSources[0])) ⇄ \(nameForID(toggleSources[1]))"
        } else {
            modeInfo = L("トグル: 自動（直前のソース）", "Toggle: Auto (previous source)")
        }
        let modeItem = NSMenuItem(title: modeInfo, action: nil, keyEquivalent: "")
        modeItem.isEnabled = false
        menu.addItem(modeItem)

        let srcItem = NSMenuItem(title: L("トグルする2ソースを選択", "Pick 2 sources to toggle"), action: nil, keyEquivalent: "")
        let srcMenu = NSMenu()
        for s in selectableKeyboardSources() {
            guard let id = stringProperty(s, kTISPropertyInputSourceID) else { continue }
            let mi = NSMenuItem(title: localizedName(s), action: #selector(toggleSourceSelection(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = id
            mi.state = toggleSources.contains(id) ? .on : .off
            srcMenu.addItem(mi)
        }
        srcMenu.addItem(.separator())
        let clearItem = NSMenuItem(title: L("選択を解除（自動に戻す）", "Clear selection (back to auto)"), action: #selector(clearToggleSources), keyEquivalent: "")
        clearItem.target = self
        clearItem.isEnabled = !toggleSources.isEmpty
        srcMenu.addItem(clearItem)
        srcItem.submenu = srcMenu
        menu.addItem(srcItem)

        menu.addItem(.separator())

        // 修飾キー サブメニュー
        let modItem = NSMenuItem(title: L("修飾キー", "Modifier keys"), action: nil, keyEquivalent: "")
        let modMenu = NSMenu()
        let mods: [(String, CGEventFlags)] = [
            ("Control (^)", .maskControl),
            ("Option (⌥)", .maskAlternate),
            ("Command (⌘)", .maskCommand),
            ("Shift (⇧)", .maskShift),
        ]
        for (title, flag) in mods {
            let mi = NSMenuItem(title: title, action: #selector(toggleModifier(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = NSNumber(value: flag.rawValue)
            mi.state = requiredFlags.contains(flag) ? .on : .off
            modMenu.addItem(mi)
        }
        modItem.submenu = modMenu
        menu.addItem(modItem)

        let comboInfo = NSMenuItem(title: L("キー: ", "Key: ") + "\(comboDescription()) + Space", action: nil, keyEquivalent: "")
        comboInfo.isEnabled = false
        menu.addItem(comboInfo)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: L("ログイン時に起動", "Launch at login"), action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        let axItem = NSMenuItem(title: L("アクセシビリティ設定を開く…", "Open Accessibility settings…"), action: #selector(openAX), keyEquivalent: "")
        axItem.target = self
        menu.addItem(axItem)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let verItem = NSMenuItem(title: L("バージョン", "Version") + " \(version)", action: nil, keyEquivalent: "")
        verItem.isEnabled = false
        menu.addItem(verItem)

        let ghItem = NSMenuItem(title: L("GitHub で開く", "View on GitHub"), action: #selector(openGitHub), keyEquivalent: "")
        ghItem.target = self
        menu.addItem(ghItem)

        let logItem = NSMenuItem(title: L("ログを書き出す…", "Export log…"), action: #selector(exportLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        let uninstallItem = NSMenuItem(title: L("アンインストール…", "Uninstall…"), action: #selector(uninstall), keyEquivalent: "")
        uninstallItem.target = self
        menu.addItem(uninstallItem)

        let quit = NSMenuItem(title: L("終了", "Quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func comboDescription() -> String {
        var parts: [String] = []
        if requiredFlags.contains(.maskControl) { parts.append("^") }
        if requiredFlags.contains(.maskAlternate) { parts.append("⌥") }
        if requiredFlags.contains(.maskShift) { parts.append("⇧") }
        if requiredFlags.contains(.maskCommand) { parts.append("⌘") }
        return parts.isEmpty ? "?" : parts.joined()
    }

    // ── メニュー アクション ───────────────────────────
    @objc func toggleEnabled() {
        enabled.toggle()
        applyEnabledState()
        saveSettings()
        rebuildMenu()
    }

    @objc func toggleModifier(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        let flag = CGEventFlags(rawValue: n.uint64Value)
        if requiredFlags.contains(flag) {
            var next = requiredFlags
            next.remove(flag)
            // 修飾キーを全部外すと、素のスペースキーが条件に一致して
            // 全アプリでスペースが飲み込まれ、文字入力ができなくなる。
            // 最後の1つは外させない。
            if next.isEmpty {
                NSSound.beep()
                logger.notice("refused to clear the last modifier key")
                return
            }
            requiredFlags = next
        } else {
            requiredFlags.insert(flag)
        }
        logger.notice("modifiers = \(self.comboDescription(), privacy: .public)")
        saveSettings()
        rebuildMenu()
    }

    // トグル対象ソースの選択。最大2つ、古いものから押し出す(FIFO)。
    @objc func toggleSourceSelection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if let idx = toggleSources.firstIndex(of: id) {
            toggleSources.remove(at: idx)          // 既に選択済み → 外す
        } else {
            toggleSources.append(id)               // 追加
            if toggleSources.count > 2 {
                toggleSources.removeFirst()        // 3つ目が来たら一番古いのを外す
            }
        }
        saveSettings()
        rebuildMenu()
    }

    @objc func clearToggleSources() {
        toggleSources.removeAll()
        saveSettings()
        rebuildMenu()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                logger.notice("login item unregistered")
            } else {
                try SMAppService.mainApp.register()
                logger.notice("login item registered")
            }
        } catch {
            logger.error("login item toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        rebuildMenu()
    }

    @objc func openAX() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openGitHub() {
        if let url = URL(string: "https://github.com/rn10/InputSourceSwitcher") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    // ── ログの書き出し ────────────────────────────────
    // ターミナルを使わない相手からも不具合報告を受け取れるように、
    // `log show` の結果をデスクトップにテキストで保存する。
    @objc func exportLog() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let dest = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InputSourceSwitcher-log-\(fmt.string(from: Date())).txt")

        // log show は数秒かかることがあるので、メインスレッドを止めない
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            p.arguments = ["show",
                           "--predicate", "subsystem == \"\(subsystemID)\"",
                           "--last", "1h",
                           "--info", "--debug",
                           "--style", "compact"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()

            var failure: String?
            do {
                try p.run()
                // waitUntilExit より先に読み切らないとパイプが詰まる
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                try data.write(to: dest)
            } catch {
                failure = error.localizedDescription
            }

            DispatchQueue.main.async {
                if let failure = failure {
                    logger.error("log export failed: \(failure, privacy: .public)")
                    NSApp.activate(ignoringOtherApps: true)
                    let a = NSAlert()
                    a.alertStyle = .warning
                    a.messageText = L("ログの書き出しに失敗しました。", "Could not export the log.")
                    a.informativeText = failure
                    a.runModal()
                } else {
                    logger.notice("log exported")
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            }
        }
    }

    // ── アンインストール ──────────────────────────────
    @objc func uninstall() {
        // 確認ダイアログ（既定はキャンセル）
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = L("InputSourceSwitcher をアンインストールしますか？",
                                "Uninstall InputSourceSwitcher?")
        confirm.informativeText = L(
            "設定を削除し、ログイン項目を解除して、アプリ本体をゴミ箱に移動します。\nアクセシビリティ権限はご自身で削除する必要があります。",
            "This deletes your settings, removes the login item, and moves the app to the Trash.\nYou must remove the Accessibility permission yourself.")
        confirm.addButton(withTitle: L("キャンセル", "Cancel"))          // 既定
        confirm.addButton(withTitle: L("アンインストール", "Uninstall"))  // 実行
        guard confirm.runModal() == .alertSecondButtonReturn else { return }

        // 1. ログイン項目を解除
        try? SMAppService.mainApp.unregister()
        logger.notice("uninstall: login item unregistered")

        // 2. 保存設定を削除
        if let bid = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bid)
            logger.notice("uninstall: user defaults removed")
        }

        // 3. アプリ本体をゴミ箱へ移動
        //    （ログはOSの統合ログに残るが、一定期間で自動的に消える）
        var trashed = true
        do {
            try FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
            logger.notice("uninstall: app moved to trash")
        } catch {
            trashed = false
            logger.error("uninstall: trash failed: \(error.localizedDescription, privacy: .public)")
        }

        // 4. 完了案内（アクセシビリティは手動削除）
        //    先に設定画面を開き、指示ダイアログは「閉じる」を押すまで残す。
        //    「アクセシビリティ設定を開く」を押しても閉じず、開き直せる。
        openAX()

        let done = NSAlert()
        var msg = L("アンインストールが完了しました。",
                    "Uninstall complete.")
        if !trashed {
            msg += L("\n（アプリ本体のゴミ箱移動に失敗しました。手動で削除してください。）",
                     "\n(Could not move the app to the Trash; please delete it manually.)")
        }
        done.messageText = msg
        done.informativeText = L(
            "アクセシビリティ権限は自動では削除できません。開いた「システム設定 > プライバシーとセキュリティ > アクセシビリティ」の一覧から InputSourceSwitcher を削除してください。\n削除できたら「閉じる」を押してください。",
            "The Accessibility permission cannot be removed automatically. In the System Settings > Privacy & Security > Accessibility list that just opened, remove InputSourceSwitcher.\nClick Close when done.")
        done.addButton(withTitle: L("閉じる", "Close"))                              // 第1: 閉じる
        done.addButton(withTitle: L("アクセシビリティ設定を開く", "Open Accessibility settings")) // 第2: 開き直す
        // 「開く」を押した場合は閉じずに開き直し、「閉じる」を押すまでループ
        while done.runModal() == .alertSecondButtonReturn {
            openAX()
        }

        NSApp.terminate(nil)
    }

    // ── タップの有効/無効 ─────────────────────────────
    func applyEnabledState() {
        guard let tap = tap else { return }
        CGEvent.tapEnable(tap: tap, enable: enabled)
        if let btn = statusItem.button {
            btn.contentTintColor = enabled ? nil : .disabledControlTextColor
        }
        logger.notice("enabled = \(self.enabled, privacy: .public)")
    }

    // ── イベントタップ設置 ────────────────────────────
    func installTap() {
        guard tap == nil else { return }   // 既に設置済みなら何もしない
        // keyDown だけでなく keyUp も対象にする（対になる keyUp を素通しさせないため）
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(mask),
            callback: tapCallback, userInfo: refcon) else {
            logger.error("failed to create event tap (accessibility not granted?)")
            return
        }
        tap = t
        let rls = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, .commonModes)
        logger.notice("event tap installed")
    }

    // ── コールバック実処理 ────────────────────────────
    // ここは「即座に返す」ことが最優先。時間のかかる処理を行うと
    // OS にタップを無効化される（tapDisabledByTimeout）。
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 「ある日突然効かなくなった」を追う唯一の手がかりなので、
            // 常時記録される .error で残す
            logger.error("event tap disabled (\(type.rawValue, privacy: .public)); re-enabling")
            if let t = tap, enabled { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown {
            let mods = event.flags.intersection(majorMask)
            if keycode == switchKeyCode && mods == requiredFlags {
                let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !repeated {
                    // 切替本体はコールバックの外へ逃がす
                    DispatchQueue.main.async { [weak self] in self?.performSwitch() }
                }
                swallowedKeyDown = true
                return nil // 飲み込む
            }
        } else if type == .keyUp {
            // 修飾キーを先に離した場合でも対になる keyUp を確実に飲み込む
            if keycode == switchKeyCode && swallowedKeyDown {
                swallowedKeyDown = false
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // ── 切替 ──────────────────────────────────────────
    func performSwitch() {
        guard let curr = currentSourceID() else { return }
        var targetID: String?

        // 決め打ちペアが2つ有効に設定されていれば、それを最優先で行き来する
        if toggleSources.count == 2,
           let a = toggleSources.first, let b = toggleSources.last,
           source(forID: a) != nil, source(forID: b) != nil {
            targetID = (curr == a) ? b : a
        } else {
            // 自動モード: 直前ソース、なければフォールバック
            targetID = previousID
            if targetID == nil || targetID == curr || source(forID: targetID!) == nil {
                targetID = selectableKeyboardSources()
                    .compactMap { stringProperty($0, kTISPropertyInputSourceID) }
                    .first { $0 != curr }
            }
        }

        guard let tID = targetID, let target = source(forID: tID) else { return }

        let status = TISSelectInputSource(target)
        logger.debug("switch \(curr, privacy: .public) -> \(tID, privacy: .public) (OSStatus \(status, privacy: .public))")
        previousID = curr
        currentID = tID

        // 反映が遅れることがあるため、複数タイミングで無条件に選び直す（ログ付き）。
        // フォーカス中フィールドへの反映が数百ms遅れるケースを拾うため後ろまで撃つ。
        let followupDelaysMs = [40, 120, 250]
        for ms in followupDelaysMs {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(ms) / 1000.0) {
                _ = TISSelectInputSource(target)
                logger.debug("followup re-select @\(ms, privacy: .public)ms -> \(tID, privacy: .public)")
            }
        }
    }

    func onSelectionChanged() {
        let now = currentSourceID()
        if now != currentID {
            previousID = currentID
            currentID = now
        }
    }
}

// ═══════════════════════════════════════════════════════
//  エントリポイント
// ═══════════════════════════════════════════════════════
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Dockに出さない
let controller = Controller()
app.delegate = controller
app.run()
