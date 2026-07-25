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
   swallows it so the app underneath never sees it. The matching key-up is
   swallowed too, so apps that track key state on their own don't see a stuck key.
2. It switches the input source **directly via the TIS API** — either toggling
   between two pinned sources, or returning to the previously used source.
3. Right after switching, it re-selects the same source once more (a
   "two-stage fire") to avoid IME activation being dropped (e.g. with ATOK).

Since it never goes through the OS shortcut-handling path, the "cold path" drop
cannot occur by construction.

The event-tap callback itself returns immediately and hands the actual switch off
to the main queue. Blocking inside the callback is what causes macOS to disable
the tap (`tapDisabledByTimeout`) — the very thing that would bring the dropped
switches back.

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
./install.sh   # installs it to /Applications
```

`build.sh` also generates the app icon (`AppIcon.icns`) from `AppIcon.iconset`
using `iconutil`, so no extra step is needed.

`install.sh` copies the app to `/Applications`, clears the quarantine flag, and
**resets the stale Accessibility registration** (see below).

---

## First launch & Accessibility permission

Because it intercepts keyboard events, **Accessibility permission is required**.

1. Launch InputSourceSwitcher (double-click it in `/Applications`).
2. Grant Accessibility when prompted. (If no prompt appears, add and enable
   InputSourceSwitcher under *System Settings > Privacy & Security >
   Accessibility*.)
3. It becomes active within a second or two of being granted — **no restart
   needed**.

If it still doesn't work after 30 seconds, the app shows a hint: a stale entry
may be left in the list. See *Updating* below.

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
  Shift) the shortcut requires. At least one is always required; the last one
  cannot be cleared, since a bare Space would then be swallowed everywhere.
- **Launch at login** — register/unregister auto-start via `SMAppService`.
- **Open Accessibility settings…**
- **Export log…** — saves the last hour of logs to a text file on your Desktop
  and reveals it in the Finder. Useful for reporting problems without touching
  the terminal.
- **Uninstall…** — see below.
- **Quit**

The UI language follows your system language (Japanese or English). Settings are
saved and restored on the next launch. The intercepted key is fixed to Space
(edit `switchKeyCode` at the top of `main.swift` to change it).

To make login-launch reliable, keep the app in `/Applications` (`SMAppService`
expects a stable location — `install.sh` places it there).

Only one instance runs at a time. If a second copy is launched it tells you and
quits, rather than fighting the first one over every switch.

---

## Logs

Logs go to the **macOS unified logging system**, not to a file of its own. That
keeps file I/O out of the event-tap callback, and means there is nothing to
rotate or clean up.

View the last hour:

```bash
log show --predicate 'subsystem == "com.naito.InputSourceSwitcher"' \
         --last 1h --info --debug
```

Follow live:

```bash
log stream --predicate 'subsystem == "com.naito.InputSourceSwitcher"' --level debug
```

In Console.app, search for `subsystem:com.naito.InputSourceSwitcher`, and enable
*Action > Include Debug Messages* to see individual switches.

Or just use **Export log…** from the menu.

What gets recorded:

| Level | Kept | Contents |
|---|---|---|
| `notice` | persisted | launch, tap installed, permission granted, settings changes |
| `error` | persisted | tap creation failure, **tap auto-recovery**, login-item errors |
| `debug` | in memory | each individual switch (`switch A -> B (OSStatus 0)`) |

The tap auto-recovery line is the one to look for if switching stops working
after running fine for a while.

---

## Updating

Just build and install again — **no need to uninstall first**:

```bash
./build.sh
./install.sh
```

Your settings (pinned toggle sources, chosen modifier keys) are preserved.

**Why `install.sh` resets the Accessibility permission.** The app is ad-hoc
signed, so its signature hash changes on every build and macOS treats each build
as a different app. The old grant stops working — but the entry stays in the
list *with its checkbox still on*, which makes it look like the permission is
fine. Unchecking and re-checking does not fix it.

`install.sh` therefore runs `tccutil reset Accessibility com.naito.InputSourceSwitcher`
so the app asks for permission cleanly on the next launch. If that command fails
(it can, depending on the macOS version), do it by hand:

*System Settings > Privacy & Security > Accessibility* → select
InputSourceSwitcher → remove it with the **“−”** button → add it again.

If you rebuild many times a day and find the re-granting tedious, you can create
a self-signed code-signing certificate and change `--sign -` in `build.sh` to its
name; the signature then stays stable across builds. It is only valid on your own
Mac and is not needed for normal use.

---

## Uninstall

From the menu bar, choose **Uninstall…** and confirm. This removes the login
item, deletes saved settings, and moves the app to the Trash. It then opens the
Accessibility settings so you can remove the InputSourceSwitcher entry — that one
entry cannot be removed automatically and must be deleted by you.

Log entries live in the unified logging system and expire on their own.

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

## Changelog

**1.1**

- The event-tap callback no longer blocks; the switch is dispatched to the main
  queue and the "two-stage fire" no longer sleeps. Prevents the tap from being
  disabled by timeout under load.
- The matching key-up is swallowed along with the key-down.
- The last modifier key can no longer be cleared (a bare Space would otherwise be
  swallowed system-wide).
- Only one instance runs at a time.
- Logging moved from `~/Library/Logs/InputSourceSwitcher.log` to the unified
  logging system; added **Export log…**.
- `install.sh` resets the stale Accessibility registration, so updating in place
  works and settings are preserved.
- A hint is shown if the permission still isn't active 30 seconds after launch.

**1.0** — initial release.

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
