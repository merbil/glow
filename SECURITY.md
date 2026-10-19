# Security

Glow holds a key that controls the lamps in someone's home, so security reports are very welcome.

**Please report vulnerabilities privately** using GitHub's
[private vulnerability reporting](https://github.com/merbil/glow/security/advisories/new)
rather than a public issue. I'll reply as soon as I can.

## How Glow protects your bridge key
- Stored in `~/Library/Application Support/Glow/appKey`, readable only by your user (file 600, folder 700).
- Never written to logs (the key is redacted from request paths; lamp names are logged as private).
- Sent only over TLS to your bridge. On first contact the bridge must present a certificate signed by
  Philips' Hue root and issued to its own bridge id; afterwards its certificate is pinned (SHA-256).
- A key pasted from another app is never sent to a device that can't prove it's a genuine Hue Bridge.
- HTTP redirects are never followed. The app runs with the hardened runtime.

## Known limitations
- **The key is a plain file, not in the macOS Keychain.** File permissions keep other *users* out, but any
  program running as *you* could read it. The Keychain would make such a program ask first. Glow used the
  Keychain until 0.1.1, but without a paid Apple Developer ID macOS asked for your password after every
  update, so the key moved to a file (as Home Assistant and most Hue tools do). Once Glow is signed with a
  Developer ID, the key will move back into the Keychain. The key only controls lamps, and only from inside
  your home network.
- The app isn't notarized by Apple (no paid developer account), so macOS asks you to confirm with
  "Open Anyway" the first time. Only download Glow from this repository's Releases page.
- "Forget Hue Bridge" removes the key from your Mac but can't revoke it on the bridge; use the
  Hue app / account for that.
