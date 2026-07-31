# Global Shortcut Candidates

- Status: comparative Workstream 1 spike; not adopted
- Owner: `L-K-M`
- Required second reviewer: macOS platform or supply-chain reviewer
- Research baseline: 2026-07-31

## Preferred Package Candidate

| Field | Value |
|---|---|
| Name | `KeyboardShortcuts` by Sindre Sorhus |
| Purpose | User-configurable global Quick Search shortcut and recorder UI |
| Exact release | `3.0.1`; commit `49c3fc04ea827f816df67843bfcc57286b47ff06`; tree `7c070f727276e9077dee4cc6b19f8ca25c831ae4` |
| Origin | <https://github.com/sindresorhus/KeyboardShortcuts/releases/tag/3.0.1> |
| Hashed artifact | <https://codeload.github.com/sindresorhus/KeyboardShortcuts/tar.gz/49c3fc04ea827f816df67843bfcc57286b47ff06> |
| Commit archive SHA-256 | `bc5d48429e2ce247cbb9026433714e05ac153b2e212d12256800391dfc202956` |
| License | MIT; retain the copyright and permission notice |
| Transitives | No declared Swift package dependency or bundled executable |
| Toolchain | Swift tools 6.2; macOS 10.15 floor |
| Integrity | Unsigned tag/commit; no publisher checksum, SBOM, or provenance |

The dependency may receive only shortcut identifiers, key codes, modifiers, and
activation callbacks. It must never receive search text, vault values,
credentials, keys, clipboard values, or provider state. VaultSquire owns the
preference representation, lock/session checks, and Quick Search action. Exact
compiled linked images and system-framework use remain unverified until the
Workstream 1 source and release-binary audit.

## Apple No-Dependency Fallback

This fallback is an Apple platform surface, not a third-party dependency
candidate. Use a small app-owned wrapper over public Carbon/HIToolbox
registered-hot-key APIs (`RegisterEventHotKey` and `UnregisterEventHotKey`) from
the exact pinned Xcode/macOS SDK. This introduces no downloaded package or
third-party transitive, but VaultSquire must own recorder UI, serialization,
conflict behavior, localization, callback lifetime, and accessibility. Global
event monitors and event taps are rejected because they broaden input
observation and permission surface.

The API is governed by the Xcode and Apple SDK agreements. Apple system
frameworks are linked from the supported OS and are not redistributed as
third-party binaries. Workstream 1 must record the selected Apple-signed Xcode
build, Swift compiler, SDK build, deployment target, and supported macOS matrix.

## Spike Gate

Compare both routes under the same app-owned boundary. Verify registration,
replacement, unregistration, duplicate/reserved/invalid chords, keyboard
layouts, input methods, sleep/wake, screen lock, fast-user switching, relaunch,
Spaces, full-screen apps, focus restoration, and stale callback rejection after
lock. Neither route may request Accessibility or Input Monitoring permission.
The selected route must pass Swift 6 concurrency, App Sandbox/direct builds,
VoiceOver/Full Keyboard Access, and the 100 ms warm-panel budget on a named Mac.

## Update And Removal Policy

Pin one exact package revision and independently recorded archive. Review weekly
and before releases; never auto-update. Keep package types behind the app-owned
boundary so the Apple wrapper can replace it without changing feature code. If
no safe global registrar exists, disable global activation while retaining an
in-app menu shortcut.
