import Cocoa
import Carbon.HIToolbox
import ServiceManagement

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

// UI言語: システムの優先言語が日本語なら日本語、それ以外は英語
let uiLang: String = {
    let pref = Locale.preferredLanguages.first ?? "en"
    return pref.hasPrefix("ja") ? "ja" : "en"
}()
// 対訳を選ぶ。L("日本語", "English")
func L(_ ja: String, _ en: String) -> String {
    return uiLang == "ja" ? ja : en
}
// 二段撃ちの間隔
let followupDelayMs: UInt32 = 25

// ログの出力先ファイル（~/Library/Logs/InputSourceSwitcher.log）
let logFileURL: URL = {
    let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("InputSourceSwitcher.log")
}()
// これを超えたら古い方を捨てる上限（約256KB）
let logMaxBytes = 256 * 1024

func appendToLogFile(_ line: String) {
    let data = Data(line.utf8)
    let fm = FileManager.default
    if let h = try? FileHandle(forWritingTo: logFileURL) {
        defer { try? h.close() }
        h.seekToEndOfFile()
        h.write(data)
    } else {
        try? data.write(to: logFileURL)   // 初回作成
    }
    // サイズ超過なら後半だけ残して切り詰め
    if let size = (try? fm.attributesOfItem(atPath: logFileURL.path)[.size]) as? Int,
       size > logMaxBytes,
       let all = try? Data(contentsOf: logFileURL) {
        let tail = all.suffix(logMaxBytes / 2)
        try? tail.write(to: logFileURL)
    }
}

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(s)\n"
    print(line, terminator: ""); fflush(stdout)
    appendToLogFile(line)
}

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
    var followupCount = 1
    var toggleSources: [String] = []   // 0個=自動モード / 2個=決め打ちトグル

    var currentID: String?
    var previousID: String?
    var permissionTimer: Timer?   // 権限付与を待つ監視タイマー

    // ── 起動 ──────────────────────────────────────────
    func applicationDidFinishLaunching(_ notification: Notification) {
        loadSettings()

        let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(axOpts)
        log("accessibility trusted = \(trusted)")

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
            log("accessibility not granted yet; watching for permission…")
            startPermissionWatch()
        }
    }

    // 権限が付くまで定期的に確認し、付いたらタップを設置してメニューへ即反映する。
    // 通常起動（既に許可済み）ではタイマーは動かない。
    func startPermissionWatch() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            guard AXIsProcessTrusted() else { return }   // まだ権限なし → 次回へ
            self.installTap()
            if self.tap != nil {
                self.applyEnabledState()
                self.rebuildMenu()
                log("permission granted; tap installed without restart")
                t.invalidate()
                self.permissionTimer = nil
            }
        }
    }

    // ── 設定の読み書き ────────────────────────────────
    func loadSettings() {
        if defaults.object(forKey: Keys.enabled) != nil {
            enabled = defaults.bool(forKey: Keys.enabled)
        }
        if let n = defaults.object(forKey: Keys.requiredFlags) as? NSNumber {
            requiredFlags = CGEventFlags(rawValue: n.uint64Value)
        }
        if let n = defaults.object(forKey: Keys.followupCount) as? NSNumber {
            followupCount = n.intValue
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
        return parts.isEmpty ? L("(修飾なし)", "(none)") : parts.joined()
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
        if requiredFlags.contains(flag) { requiredFlags.remove(flag) }
        else { requiredFlags.insert(flag) }
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
                log("login item unregistered")
            } else {
                try SMAppService.mainApp.register()
                log("login item registered")
            }
        } catch {
            log("login item toggle failed: \(error)")
        }
        rebuildMenu()
    }
    @objc func openAX() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func quit() { NSApp.terminate(nil) }

    // ── アンインストール ──────────────────────────────
    @objc func uninstall() {
        // 確認ダイアログ（既定はキャンセル）
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = L("InputSourceSwitcher をアンインストールしますか？",
                                "Uninstall InputSourceSwitcher?")
        confirm.informativeText = L(
            "設定・ログを削除し、ログイン項目を解除して、アプリ本体をゴミ箱に移動します。\nアクセシビリティ権限はご自身で削除する必要があります。",
            "This deletes settings and logs, removes the login item, and moves the app to the Trash.\nYou must remove the Accessibility permission yourself.")
        confirm.addButton(withTitle: L("キャンセル", "Cancel"))          // 既定
        confirm.addButton(withTitle: L("アンインストール", "Uninstall"))  // 実行
        guard confirm.runModal() == .alertSecondButtonReturn else { return }

        // 1. ログイン項目を解除
        try? SMAppService.mainApp.unregister()
        log("uninstall: login item unregistered")

        // 2. 保存設定を削除
        if let bid = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bid)
            log("uninstall: user defaults removed")
        }

        // 3. ログファイルを削除
        try? FileManager.default.removeItem(at: logFileURL)

        // 4. アプリ本体をゴミ箱へ移動
        var trashed = true
        do {
            try FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
            log("uninstall: app moved to trash")
        } catch {
            trashed = false
            log("uninstall: trash failed: \(error)")
        }

        // 5. 完了案内（アクセシビリティは手動削除）
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
        log("enabled = \(enabled)")
    }

    // ── イベントタップ設置 ────────────────────────────
    func installTap() {
        guard tap == nil else { return }   // 既に設置済みなら何もしない
        let mask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(mask),
            callback: tapCallback, userInfo: refcon) else {
            log("ERROR: failed to create event tap (accessibility not granted?)")
            return
        }
        tap = t
        let rls = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, .commonModes)
        log("event tap installed")
    }

    // ── コールバック実処理 ────────────────────────────
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap, enabled { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown {
            let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let mods = event.flags.intersection(majorMask)
            if keycode == switchKeyCode && mods == requiredFlags {
                let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !repeated { performSwitch() }
                return nil // 飲み込む
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
        let s = TISSelectInputSource(target)
        for _ in 0..<followupCount {
            usleep(followupDelayMs * 1000)
            _ = TISSelectInputSource(target)
        }
        log("switch \(curr) -> \(tID) (OSStatus \(s))")
        previousID = curr
        currentID = tID
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
