import Cocoa

// このMacでイベントタップにキーイベントが届くかを検証する最小プログラム。
// アプリバンドル・署名を介さず、ターミナルから直接動かす。
// キーを押すたびにキーコードを表示するだけ。Ctrl+C で終了。

let mask = (1 << CGEventType.keyDown.rawValue)

let callback: CGEventTapCallBack = { _, _, event, _ in
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    print("keyDown: keycode=\(keycode)")
    fflush(stdout)
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,          // 監視のみ（キーは飲み込まない）
    eventsOfInterest: CGEventMask(mask),
    callback: callback,
    userInfo: nil) else {
    print("FAILED to create event tap. Accessibility not granted to the terminal?")
    exit(1)
}

let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("tap installed. Press keys (Ctrl+C to quit)...")
fflush(stdout)
CFRunLoopRun()
