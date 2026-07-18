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

## Build & Install

```bash
git clone https://github.com/rn10/InputSourceSwitcher.git
cd InputSourceSwitcher
./build.sh     # compiles and builds InputSourceSwitcher.app (ad-hoc signed, with icon)
./install.sh   # copies it to /Applications and clears the quarantine flag
```

`build.sh` also generates the app icon (`AppIcon.icns`) from `AppIcon.iconset`
using `iconutil`, so no extra step is needed.

---

## First launch & Accessibility permission

Because it intercepts keyboard events, **Accessibility permission is required**.

1. Launch InputSourceSwitcher (double-click it in `/Applications`).
2. Grant Accessibility when prompted. (If no prompt appears, add and enable
   InputSourceSwitcher under *System Settings > Privacy & Security >
   Accessibility*.)
3. It becomes active within a second or two of being granted — **no restart
   needed**.

---

## Usage

Click the menu-bar icon:

- **有効 / Enabled** — turn interception on/off. When off, `^Space` passes
  through untouched (handy when registering input-source shortcuts in System
  Settings).
- **Pick 2 sources to toggle** — lists your enabled input sources by name.
  **Select two** and `^Space` toggles only between those two. "Clear selection"
  returns to automatic mode (switch to the previously used source).
- **Modifier keys** — choose which modifiers (Control / Option / Command /
  Shift) the shortcut requires.
- **Launch at login** — register/unregister auto-start via `SMAppService`.
- **Open Accessibility settings…**
- **Uninstall…** — see below.
- **Quit**

The UI language follows your system language (Japanese or English). Settings are
saved and restored on the next launch. The intercepted key is fixed to Space
(edit `switchKeyCode` at the top of `main.swift` to change it).

To make login-launch reliable, keep the app in `/Applications` (`SMAppService`
expects a stable location — `install.sh` places it there).

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

## Reinstalling (updating)

To reinstall or update, first run **Uninstall…** from the menu, then run
`./build.sh` and `./install.sh` again. **Do not just overwrite** the app in
`/Applications` — doing so can cause odd behavior due to signature/permission
mismatches.

Note that uninstalling **erases your saved settings** (pinned toggle sources,
chosen modifier keys, etc.), so you will need to reconfigure and re-grant
Accessibility after reinstalling.

---

## Uninstall

From the menu bar, choose **Uninstall…** and confirm. This removes the login
item, deletes saved settings and logs, and moves the app to the Trash. It then
opens the Accessibility settings so you can remove the InputSourceSwitcher
entry — that one entry cannot be removed automatically and must be deleted by
you.

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
