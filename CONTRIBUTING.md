# Contributing

Thanks for helping! Issues and pull requests are welcome.

## Setup
- macOS 14+, Apple Command Line Tools (`xcode-select --install`) or Xcode.
- `swift build && .build/debug/Glow --demo` runs Glow with sample lamps — no bridge needed.

## Before opening a PR
- `.build/debug/Glow --selftest` must pass (it also runs in CI).
- If you touch the bridge connection, also run `.build/debug/Glow --pentest` (needs `openssl`):
  it attacks Glow with a fake bridge and a forged certificate.
- Add a line to `RELEASE_NOTES.md` under the next version.

## Signing your own builds
`scripts/build-app.sh` signs with a certificate called **"Glow Local Signing"** if your login keychain
has one, otherwise ad-hoc. A stable local certificate keeps macOS's Local Network permission across
rebuilds. Create your **own** (never share or commit its private key — anything signed with it is
treated as the same app by your Mac).

## Useful flags (debug builds)
| Flag | What it does |
|---|---|
| `--demo` | Runs the menu bar app with sample lamps |
| `--snapshot out.png [--light] [--timer] [--page arrange]` | Renders the popover to a PNG |
| `--menu-shot out.png Corner` | Captures the real right-click menu |
| `--selftest` / `--pentest` | Built-in tests / TLS attack tests |
| `--e2e` | Live test against your paired bridge (toggles real lamps, then restores them) |
