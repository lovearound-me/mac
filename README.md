# Mac app

Menu bar only (`LSUIElement`), macOS 13+, universal (Apple Silicon + Intel).
SwiftPM, no Xcode project. The bundle is `Love Around.app`, id
`me.lovearound.mac`; "Needed" is the codename kept by the executable. Links
are `lovearound://`; the codename's `needed://` still works for old pages.
Up to 0.1.48 the id was `app.needed.mac`: `Migration.swift` copies its
settings and moves the session over on the first launch.

## What it does

- A heart in the menu bar opens a popover: "О ком ты сейчас думаешь?", the
  sparkles circle for "Кому-нибудь на свете", the people "рядом" as
  circles (dragged to reorder), then the rest of the list. A click sends a bare
  signal. Each opening starts on this screen. A right click on the heart:
  pause, settings, "Проверить обновления…", quit. No global hotkeys, on purpose: they clash with other
  apps, and a signal should be a deliberate tap.
- What takes longer than a glance is a window: the book (on the left "Рядом"
  in circle order, then "Остальные"; a drag moves people between the two
  and reorders the circles; name, color and removal on the right; adding by
  link lives here and behind the "+" circle) and the settings (Сигнал / Когда /
  Устройства / Аккаунт, ⌘,). The app still has no Dock icon. In the code and
  the API "рядом" is still `close`.
- An incoming signal lights the edges of every screen in the receiver's own
  color, with a mix of hearts, hugs, cats, flowers and more floating up. The
  receiver never learns who sent it.
- The popover and the windows follow the system's light or dark appearance (`Palette.swift`).
- Contact colors and the user's signal color live in `UserDefaults` on this
  Mac only — the server stores no colors (see the API docs at [lovearound.me/docs](https://lovearound.me/docs)).

## Layout

| File | Contains |
|---|---|
| `Config.swift` | API base URL, Firebase web API key, site URL, URL scheme |
| `Auth.swift` | Firebase Auth over REST: email+password, reset, token refresh, Google via the site |
| `API.swift` | `/v1` client; retries once on 401 with a fresh token |
| `Stream.swift` | `WS /v1/stream`, ping every 30 s, reconnect with 1→60 s backoff |
| `Presenting.swift` | full screen or a mirrored display: incoming signals stay quiet |
| `Overlay.swift` | one click-through window per screen, Core Animation glow + emoji |
| `AppModel.swift` | state, local settings, `lovearound://` link handling |
| `App.swift` | entry point, status item, popover and its right-click menu |
| `Windows.swift` | the book and settings windows |
| `Migration.swift` | settings and session from the old `app.needed.mac` |
| `Updates.swift` | Sparkle: hourly check, background download, relaunch when the app isn't in use |
| `Views.swift`, `Palette.swift` | SwiftUI screens and the warm palette |

## Sign-in

- **Email:** `signInWithPassword`, falling back to `signUp` for a new address.
- **Google:** the app opens `https://lovearound.me/signin?state=<uuid>&key=<a
  one-time P-256 public key>`.
  The page signs in with the Firebase JS SDK (in-memory, nothing kept in the
  browser), seals uid, email and the refresh token to that key and redirects
  to `lovearound://signin?state=…&epk=…&box=…`, then signs out. Only this app
  can open the box (`SignInBox.swift`); it accepts only the state it
  generated.
- The session (uid, email, refresh token) is stored in
  `~/Library/Application Support/Love Around/session.json`, mode 0600.

## Links

- `https://lovearound.me/i/<uid>` → "Открыть приложение" →
  `lovearound://add/<uid>` → the add-contact form with name and color.

## Build

```sh
xcode-select --install   # Command Line Tools, Swift 5.9+
./build.sh               # → dist/Love Around.app, dist/LoveAround.dmg
./publish.sh             # → the GitHub release v0.2.<N> + appcast
```

With a "Developer ID Application" identity in the login keychain, `build.sh`
signs the app with it (hardened runtime, Sparkle's helpers inside out), then
signs, notarizes and staples the .dmg via the notarytool keychain profile
`lovearound` (`xcrun notarytool store-credentials lovearound …`). The first
signing asks "codesign wants to sign using key…": "Always Allow" adds
codesign to that key's access list, and later builds sign without a prompt
(until then the build waits on the dialog). Without the identity the build is
ad-hoc signed (`codesign -s -`), not notarized: on first launch macOS asks to
confirm in Privacy & Security (steps are on the site).
`publish.sh` releases `dist/LoveAround.dmg`; `https://lovearound.me/download/LoveAround.dmg`
redirects to the latest release.

## Updates

[Sparkle](https://sparkle-project.org) 2, a SwiftPM dependency; `build.sh`
copies `Sparkle.framework` into `Contents/Frameworks`. The app reads
`https://lovearound.me/download/appcast.xml` every hour (`SUFeedURL`,
`SUScheduledCheckInterval` in `Resources/Info.plist`), downloads a newer
`CFBundleVersion` (100 + the commit count of this repository; the version is
`0.2.<count>`, and the 0.1.x builds, up to build 92, came from the old shared
repository) in the background and installs it as
soon as the app isn't the active one, then relaunches.

`build.sh` writes `dist/LoveAround.version` (build number, version and
`notarized` / `signed` / `adhoc`) next to the dmg. Test builds go with
`NOTARIZE=0` (signed, no wait on Apple); `publish.sh` refuses anything
but `notarized` unless `ALLOW_UNNOTARIZED=1`, makes the GitHub release
`v<version>` of this repository with the dmg and an appcast that points at it,
and signs the dmg
with the EdDSA key in `~/.config/lovearound/sparkle_ed25519.pem` on the
publishing machine. The public half is `SUPublicEDKey`. Lose the key and the
installed apps can't be updated any more, so it has a backup copy elsewhere.
lovearound.me/download/appcast.xml and /download/LoveAround.dmg redirect to
the latest release (firebase.json in the site repo).
