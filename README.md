# InputSourceSwitcher

*[日本語版 README](README.jp.md)*

A tiny menu-bar utility for macOS that works around a long-standing bug where
**the first input-source switch after an idle period is dropped or delayed**.
It intercepts a shortcut (default `^Space`) and switches the input source
**directly**, bypassing the OS shortcut-handling path that causes the drop.

Written in Swift, single file, no external dependencies. Built from source.

---

## Background — does this sound familiar?

- After not switching input sources for a while, pressing `^Space` does
  **nothing on the first one or two tries**, then switches a moment later.
- It happens not only between Japanese and English, but also between English
  and other Western keyboard layouts.
- Changing the IME, reassigning the shortcut, or using "select the previous
  source" instead of "next source" — none of these fix it.

This is a long-reported macOS behavior: the input-source switching triggered by
the shortcut seems to "go cold" when it hasn't been used for a while, dropping
the next first press. Because settings tweaks don't address the root cause, this
tool **avoids going through the OS shortcut path at all**.

---

## How it works

1. A `CGEventTap` intercepts the configured shortcut (default `^Space`) and
   swallows it so the app underneath never sees it.
2. It switches the input source **directly via the TIS API** — either toggling
   between two pinned sources, or returning to the previously used source.
3. Right after switching, it re-selects the same source once more (a
   "two-stage fire") to avoid IME activation being dropped (e.g. with ATOK).

Since it never goes through the OS shortcut-handling path, the "cold path" drop
cannot occur by construction.

---

## Requirements

- macOS 13 (Ventura) or later (login-item support uses `SMAppService`)
- Xcode Command Line Tools (you just need `swiftc`)
  - Install with `xcode-select --install` if needed
- Apple Silicon or Intel

---

## Build

```bash
git clone https://github.com/<your-account>/InputSourceSwitcher.git
cd InputSourceSwitcher
./build.sh
```

`build.sh` compiles the source, assembles `InputSourceSwitcher.app`, and
**ad-hoc signs** it (`codesign --sign -`). The result is placed in the current
directory. To install it:

```bash
cp -r ./InputSourceSwitcher.app /Applications/
```

---

## First launch & Accessibility permission

Because it intercepts keyboard events, **Accessibility permission is required**.

1. Launch `InputSourceSwitcher.app` (double-click in Finder).
2. Grant Accessibility when prompted. (If no prompt appears, add and enable
   InputSourceSwitcher under *System Settings > Privacy & Security >
   Accessibility*.)
3. **Quit the app and launch it again.**

Step 3 is needed because a permission granted after launch is not applied to the
already-running process. This is a one-time step.

---

## Usage

Click the menu-bar icon:

- **有効 (Enabled)** — turn interception on/off. When off, `^Space` passes
  through untouched (handy when registering input-source shortcuts in System
  Settings).
- **トグルする 2 ソースを選択 (Pick 2 sources to toggle)** — lists your enabled
  input sources by name. **Select two** and `^Space` will toggle only between
  those two. "Clear selection" returns to automatic mode (switch to the
  previously used source).
- **修飾キー (Modifier keys)** — choose which modifiers (Control / Option /
  Command / Shift) the shortcut requires.
- **ログイン時に起動 (Launch at login)** — register/unregister auto-start via
  `SMAppService`.
- **アクセシビリティ設定を開く… (Open Accessibility settings…)**
- **終了 (Quit)**

Your settings are saved and restored on the next launch. The intercepted key is
fixed to Space (edit `switchKeyCode` at the top of `main.swift` to change it).

To make login-launch reliable, place the app in `/Applications` before enabling
"Launch at login" (`SMAppService` expects a stable location).

---

## Logs

Runtime logs are appended here (size-capped, auto-trimmed):

```
~/Library/Logs/InputSourceSwitcher.log
```

Also viewable in Console.app. To tail in a terminal:

```bash
tail -f ~/Library/Logs/InputSourceSwitcher.log
```

A successful switch logs a line like `switch A -> B (OSStatus 0)`. If you feel a
switch was dropped, check the lines around that time.

---

## A note on rebuilding (ad-hoc signing)

An ad-hoc signature changes on every build, so macOS may treat each build as a
different app and **ask you to re-grant Accessibility permission after
rebuilds**. If you rebuild often, create a code-signing self-signed certificate
and change the signing line in `build.sh` from `--sign -` to your certificate
name; the signature then stays stable and the permission persists. (Such a
certificate is only valid on your own Mac and is not for distribution.)

---

## Uninstall

1. Quit the app from the menu bar. (If you enabled "Launch at login", turn it
   off first.)
2. Remove the app:
   ```bash
   rm -rf /Applications/InputSourceSwitcher.app
   ```
3. Remove saved settings:
   ```bash
   defaults delete com.naito.InputSourceSwitcher
   ```
4. Remove the log:
   ```bash
   rm -f ~/Library/Logs/InputSourceSwitcher.log
   ```
5. Remove the InputSourceSwitcher entry under *System Settings > Privacy &
   Security > Accessibility*.

---

## Disclaimer

This software is provided "as is", without warranty of any kind. Use it at your
own risk. The author is not liable for any damages arising from its use.

**About Accessibility permission:** by design this tool requires Accessibility
permission (i.e. the ability to observe keyboard events). However, it only
intercepts the configured shortcut (default `^Space`); every other keystroke is
passed through unmodified. It does not record or transmit any input. The source
is public, so you can verify its behavior directly in the code.

---

## License

MIT License. See [LICENSE](LICENSE).

---

## Acknowledgments

- The "two-stage fire" idea (re-selecting the source right after switching to
  ensure it takes) draws on the prior open-source projects **SwitchIM** and
  **kawa**.
- The code for this project was written end-to-end with the help of
  **Anthropic's Claude**, through iterative dialogue — the design, debugging,
  and implementation were all worked out in conversation.
