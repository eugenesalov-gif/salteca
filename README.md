> 🇷🇺 **Русская версия:** [README.ru.md](README.ru.md)

# Salteca

**Salteca** is a macOS utility that fixes text typed in the wrong keyboard layout
on the fly (`ghbdtn` → `привет`, `руддщ` → `hello`) and switches the system
layout to match the corrected result, so you can keep typing in the right one.

It lives in the menu bar, with no Dock icon.

## About

The project grew out of a personal annoyance: you catch yourself having typed a
whole phrase without switching layout, and then you have to erase it, switch, and
retype from scratch. Existing solutions are either paid, heavy, or don't switch
the actual system layout after correcting. I wanted a lightweight menu-bar tool
that does exactly one thing and does it invisibly.

It's a port and evolution of my own Python prototype into native Swift — for
speed, robust access to system APIs, and distribution as a single `.app`.

## Privacy

Salteca is built to keep what you type on your machine:

- **No network access.** The app never connects to the internet. There is no
  `URLSession`, HTTP client, socket, or any networking code anywhere in the
  source, and no network entitlement is even requested.
- **Nothing you type is written to disk.** The text you type — and the words
  captured and corrected — is never saved to any file, log, or `UserDefaults`.
  The only persisted data is app configuration (chosen hotkey, switch sound,
  and a saved alert-volume value for restoration). The last correction is held
  in memory only (to support the toggle/revert), and is lost on quit.
- **Your clipboard is preserved.** Correction is applied via the clipboard, so
  the app saves your real clipboard first and restores it via `defer` on every
  path in both the hotkey and auto-mode flows. This is guaranteed for **text**
  clipboard contents. It is **not** guaranteed for non-text contents (images,
  files) or an empty clipboard — in that case there is no string to read back,
  so the original content is not restored (this matches the original Python
  prototype's behavior).

## Features

- **Auto mode** — corrects words as you type, in the background, no hotkey needed.
  When a word is finished (space / Enter / punctuation), the layout is checked and,
  if wrong, the text is rewritten in place.
- **Hotkey mode** — corrects the selected or last word on a global hotkey
  (⇧⌘X by default). Pressing the hotkey again on an already-corrected word reverts
  it.
- **Configurable hotkey** — the shortcut can be reassigned in Settings.
- **Switch sound** — a short cue played exactly at the moment of a *confirmed*
  layout switch (choose a sound or turn it off).
- **Launch at login** — registered via `SMAppService`; the system is the source of
  truth, so the checkbox always reflects the real state.

## Technical details / architecture

Stack: **Swift / SwiftUI**, **Carbon Text Input Sources (TIS) API** for layouts,
the **Accessibility (AX) API** and **CGEvent** for reading/replacing text, and
`SMAppService` for launch-at-login. No third-party dependencies.

A few decisions that make this an interesting engineering problem:

- **Carbon TIS must run on the main thread.** `TISCreateInputSourceList` /
  `TISSelectInputSource` must be called on the main thread — otherwise it's a
  `dispatch_assert_queue_fail` crash. Text capture, however, runs on a background
  serial queue, so all layout lookup and switching is done in a single hop to main
  (`DispatchQueue.main.sync`, which is safe here because TIS calls are fast and
  don't spin the run loop).

- **Switching is confirmed by a notification, not a timer.** The old approach
  waited a fixed delay (~0.5 s) after switching — slow and unreliable: the user's
  keystrokes landed mid-switch and the event tap misread characters. Now the code
  blocks on a semaphore until the distributed
  `kTISNotifySelectedKeyboardInputSourceChanged` notification arrives (with a short
  failsafe timeout). The sound plays exactly on confirmation. Foreign switches
  (e.g. a manual Cmd+Space) are ignored — we only signal on a switch to our target.

- **"Document frozen during a correction."** In auto mode, backspace + paste
  physically mutate the document for ~0.3 s. During that whole window real
  keystrokes are suppressed at the event tap and queued, then after the correction
  they're "typed through" into the correct position and re-fed to the engine
  (cascading corrections). This keeps the engine's model and the real document in
  lockstep, and makes word segmentation independent of timing.

- **Race conditions and settle delays.** Synthetic arrows/copy need micro-pauses so
  the target app applies the selection before we read it. The hotkey is still
  physically held down at launch — we wait for the modifiers to be released,
  otherwise Cmd+C becomes Cmd+Shift+C. The user's real clipboard is saved and
  reliably restored via `defer`, and the system beep is muted for the duration of
  the operation.

- **A pure core under test.** Layout detection, character mapping, input-source
  matching, and hotkey config are extracted into pure functions covered by unit
  tests (`SaltecaTests/`) — including the trap where the substring `"us"` inside
  `"russian"` broke naive English-layout detection.

Overall structure: `AppController` is the single owner of state and services
(two-way bound to the SwiftUI menu/settings); the services (`TextCaptureService`,
`AutoModeService`, `LayoutSwitcher`, `HotKeyManager`) are `Sendable` and run on
their own background threads.

## Requirements

- macOS 26.5 or newer (Apple Silicon).
- **Accessibility** permission (see below) — without it, text capture and
  replacement won't work.

## Installation

1. Open `Salteca-1.0.0.dmg` and drag **Salteca.app** into **Applications**.
2. On first launch, get past the Gatekeeper warning (see below).
3. Grant Accessibility access (see below).

## Running past the "unidentified developer" warning

> **Note.** This project has no paid Apple Developer account, so the app is **not
> notarized** (notarization requires the $99/year account and a Developer ID
> certificate). The app is **ad-hoc signed** — the signature is valid and the app
> is not considered "damaged", but Gatekeeper will still warn that the developer is
> unverified. This is expected for distribution outside the App Store without an
> account.

The downloaded `.dmg` gets a quarantine attribute, which triggers Gatekeeper.
Get past it with one of these:

**Option 1 — via Settings (recommended, works on all versions):**
1. Try to open `Salteca.app` (a warning appears — dismiss it).
2. Go to **System Settings → Privacy & Security**.
3. Near the bottom find "Salteca was blocked…" → click **Open Anyway**, confirm.

**Option 2 — right-click (macOS 14 and older):**
- Control-click `Salteca.app` → **Open** → in the dialog, **Open** again.

**Option 3 — via Terminal (remove quarantine manually):**
```sh
xattr -dr com.apple.quarantine /Applications/Salteca.app
```

## Required permissions (Accessibility)

Salteca reads and replaces text through system keyboard events, so it needs
Universal Access:

1. **System Settings → Privacy & Security → Accessibility.**
2. Enable the toggle next to **Salteca** (add it with "+" if needed).

> **Ad-hoc signing caveat.** Every new build has a different signature, and macOS
> ties the Accessibility permission to the signature — so after a rebuild you may
> need to remove the old Salteca entry from the list and re-enable it.

## Building from source

Requires Xcode (Command Line Tools) and [`create-dmg`](https://github.com/create-dmg/create-dmg):

```sh
brew install create-dmg
./scripts/build-dmg.sh
```

The script does a clean Release build, signs it ad-hoc, and packages it into
`dist/Salteca-<version>.dmg`. The version comes from the project's
`MARKETING_VERSION`.

Running the tests:
```sh
xcodebuild test -scheme Salteca -destination 'platform=macOS'
```

## Signing status

| | Status |
|---|---|
| Ad-hoc signature | ✅ yes (valid self-signed) |
| Developer ID | ❌ no (needs a paid account) |
| Notarization | ❌ no (needs a paid account) |
| Auto-updates (Sparkle) | ⏳ planned as a separate step |
