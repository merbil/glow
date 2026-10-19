# Glow release notes

## 0.3.1 (build 9): 2026-10-19

### Security
Thanks to a friend's review:
- **A pasted Hue key is no longer sent on the first request.** Before, the very first contact with the bridge already carried the key, before Glow had checked that the bridge is genuine. The first contact now never carries a key, and the key is used only after the bridge has proven itself.
- **Pairing with the bridge button now requires a genuine Philips Hue Bridge.** Before, button pairing went ahead even when the bridge couldn't prove it was genuine, so someone intercepting setup could have received the new key. Both pairing paths now verify first (the certificate is signed by Philips' Hue root and issued to that bridge), then pin the certificate for the rest of setup. Every bridge that can run Glow (Hue API v2) has such a certificate.
- New regression tests check what the first request carries, and that button pairing stops at an unverified bridge.

### Fixed
- In dark mode, the **Warm / Daylight / Bright white** labels in the right-click menu were dark text on a dark background. They now follow the menu's appearance.

## 0.3.0 (build 8): 2026-10-19

First public release.

### Added
- **Installer:** a DMG with drag-to-Applications. Glow isn't notarized by Apple, so the first launch needs *System Settings → Privacy & Security → Open Anyway*. The DMG includes a short read-me.
- **App icon.**
- **Universal app:** runs natively on Apple Silicon and Intel Macs.

### Changed
- New app identifier `com.merterbil.glow`. Settings from earlier versions (bridge, renames, order, hidden items) carry over automatically. macOS asks once again to allow local network access.

## 0.2.1 (build 7): 2026-10-19

Security and privacy update, after a code audit and live attack tests.

### Security
- **A pasted Hue key is only sent to a genuine Philips Hue Bridge.**
  - Glow checks that the bridge's certificate is signed by Philips' Hue root and issued to the bridge's own ID.
  - A fake "bridge" on the network can no longer collect a key pasted from Home Assistant. This was tested with a forged certificate.
- **Redirects are never followed**, so the key can't be carried to another server.
- **Hardened runtime** is switched on, so other programs can't inject code into Glow.
- Diagnostic modes (`--e2e`, `--diagnose`) are off in normal installs.
- Invalid bridge addresses are rejected instead of crashing Glow.
- Bridge replies have size limits, and lamp and room names are cleaned of invisible formatting characters that could disguise a name.

### Privacy
- Lamp and room names, network details and response headers are no longer written to the macOS system log in readable form.
- Pairing now registers Glow on the bridge as `glow#mac` instead of your computer's name.
- No personal values (IP addresses, bridge IDs) in the source code.

## 0.2.0 (build 6): 2026-10-19

### Added
- **Room switches:** each room has an on/off switch next to its name, which turns the whole room on or off with one command.
- **Arrange & Hide** (gear → Arrange & Hide…):
  - drag rooms and lamps into your own order
  - hide rooms or lamps you don't need with the eye button
  - Reset Order and Show All bring everything back
  - right-click a room title to hide it quickly
- **Settings window** (gear → Settings…, or ⌘,):
  - **General:** appearance (Match System, Light or Dark), open at login, bridge status, Forget Hue Bridge.
  - **About:** version, build, and these release notes.
- After an update, a small banner offers **What's new**.

### Changed
- The right-click color menu **stays open** after you pick a color, so you can try a few. Click anywhere outside to close it.
- **Forget Hue Bridge** asks *"Are you sure?"* before doing anything.
- **Rename** opens a small page inside Glow instead of a system dialog, which was unreliable in menu bar popovers.

## 0.1.2 (build 3): 2026-10-19

### Fixed
- **Repeated Keychain password prompts.**
  - macOS ties a Keychain "Always Allow" to each build of an app without a paid Apple developer certificate, so every update asked again.
  - Glow now keeps the Hue key in a private file (`~/Library/Application Support/Glow/appKey`, permissions 600), the same approach Home Assistant uses.
  - The key moves over from the Keychain once, which may show **one last prompt**. After that, Glow never uses the Keychain.
- The self-test no longer reads the real key, which had also caused Keychain prompts.

## 0.1.1 (build 2): 2026-10-19

First version running against the real Hue Bridge. Verified with a live end-to-end test (19/19).

### Fixed
- **"Can't reach the Hue Bridge" right after pairing:**
  - The live-update stream never accepted the bridge's certificate. The cause was `URLSession.bytes` skipping the session's trust handler.
  - Normal requests worked, which is why the app loaded once and then went offline.
- **All off switched some lamps *on*** (e.g. a lamp that was already off):
  - The old command used the v1 "all lights" group with a fade, and the bridge reacted to it by switching lamps on.
  - All off now uses the v2 home group with a plain "off", and the bridge timer sends a plain "off" too.
  - Both were verified live: no lamp switches on.
- **No more fade when turning off.** Lamps no longer come back at 0% brightness the next time they're turned on.
- **Permissions reset after every update:** Glow is now signed with a local "Glow Local Signing" certificate. macOS keeps its Local Network permission across updates.
- A macOS Local Network block now shows a clear message with a button to open the right settings, instead of "No Hue Bridge answered".

### Added
- Pairing with an existing Hue key from another app (e.g. Home Assistant), as an alternative to the bridge button.
- Pairing waits 3 minutes instead of 60 seconds, with a visible countdown. **Try Again** re-pairs with the bridge it already found.
- Diagnostics for troubleshooting:
  - detailed connection logging, with the key redacted
  - `--diagnose <ip>` for connection checks
  - `--e2e` for a live end-to-end test that restores all lamps afterwards


## 0.1.0 (build 1): 2026-10-19

The first version of Glow: a menu bar app for Philips Hue lamps.

### Lights at a glance
- A bulb icon in the menu bar opens a popover with every lamp, grouped by your Hue rooms. Lamps without a room appear under **Other**.
- Each lamp is a rounded tile that glows in the lamp's real color. The fill shows its brightness, and lamps that are off are quiet grey tiles.
- The header shows how many lamps are on (e.g. "5 of 13 on"). The menu bar icon is filled when any lamp is on.
- Unreachable lamps (e.g. switched off at the wall) appear faded and say so.

### Control
- **Click** a tile to turn the lamp on or off.
- **Drag sideways** on a tile to set the brightness; dragging to 0 turns the lamp off.
- **Right-click** a tile for a menu showing only what that lamp supports:
  - color lamps: 16 color dots plus 3 whites (Warm, Daylight, Bright white)
  - white-ambiance lamps: the 3 whites only
  - single-color lamps: no color choices
- **All off ▾:**
  - turn everything off now, or in 5, 15 or 30 minutes or 1 hour
  - the timer runs on the bridge, so it works even when the Mac sleeps
  - a countdown pill shows the time left, and ✕ cancels it
- **Rename** and **hide** lamps from the right-click menu. These change Glow only, never your Hue setup.

### Connection
- Finds the Hue Bridge automatically (Bonjour, then Philips' discovery service), or you type its IP address.
- Pairs once by pressing the bridge button. The key is stored on this Mac.
- Talks to the bridge directly on your home network: no cloud and no account.
- Live updates: changes made in the Hue app, by Alexa or by a wall switch appear immediately.
- Finds the bridge again if your router gives it a new IP address, and recovers after the Mac wakes from sleep.
- Checks the bridge's security certificate and remembers it.

### Comfort
- Follows macOS dark and light mode.
- Keyboard: Tab to a tile, Space/Return toggles, ← → change brightness.
- VoiceOver: lamp names and states are read out, and brightness and the menu can be used without a mouse.
- Respects Reduce Motion and Increase Contrast. Text on tiles stays readable on every lamp color.
- Optional: open at login.
