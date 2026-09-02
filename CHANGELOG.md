# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] — 2026-09-02

### Added
- Reachability probing for iPhones that `devicectl` reports as `unavailable`, which is the normal
  state for a phone reachable only over Wi-Fi.
- `devicectl --json-output` parsing, with the old table output kept as a fallback.
- Developer Mode and signing identity checks in `autorenew doctor`.
- **Troubleshoot Device…** in the menu bar.
- Custom app icon and menu-bar glyph, rendered at install time by `make_icon.swift`.

### Changed
- The menu-bar icon turns orange when an app is due but no iPhone is reachable, separating "you need
  to plug your phone in" from "a build failed".

## [1.0.0]

- First working version: registry, scheduler, renew engine, menu-bar app and `autorenew` CLI.
