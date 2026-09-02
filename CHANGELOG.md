# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] — 2026-09-02

### Fixed
- A phone that answered a reachability probe was reported as unreachable for the rest of the
  five-minute probe cooldown, because the cooldown skipped the device instead of reusing its last
  answer. On Wi-Fi this showed up as an orange menu-bar icon, a "connect your iPhone" notification
  and a skipped renewal for a phone that was sitting right there. Probe results — successes and
  failures — are now remembered for the cooldown.

### Changed
- Device state is reported the way `devicectl` reports it. The raw `tunnelState` is kept for logs,
  but an idle phone on Wi-Fi now reads `available (paired)` instead of `disconnected`, which is what
  `devicectl list devices` and Xcode show for the same phone. `autorenew devices`, `doctor`, the
  menu-bar tooltip and **Troubleshoot Device…** also say plainly whether a device is reachable and
  whether that came from a probe.

## [1.2.0] — 2026-09-02

### Fixed
- A device whose `tunnelState` was `disconnected` was treated as reachable, because the check looked
  for `connected` as a substring. The state's first word is now compared exactly, so such a phone is
  probed like any other unreachable one instead of being built against blindly.
- The menu-bar app and the CLI no longer overwrite each other's registry. Both re-read `apps.json`
  when it changes on disk, so an `autorenew add` from a terminal appears in the running app and
  survives the app's next save.
- `autorenew renew` no longer widens a single-app request into "renew everything" when the given app
  id is no longer registered.
- `autorenew remove`/`renew --app` refuse an ambiguous name instead of acting on whichever match
  came first.
- Lowering the renew threshold no longer leaves the urgent "plug your phone in" warning firing
  before the renewal it is warning about.

### Changed
- `autorenew renew` exit codes: `0` renewed or nothing due, `1` a renewal failed, `2` no reachable
  iPhone.
- When several iPhones are reachable, a wired one is preferred and the choice is stable between
  passes rather than depending on the order `devicectl` happened to list them.
- `install.sh` copies the `autorenew` binary into `bin` instead of symlinking into `.build/`, so
  moving or cleaning the clone no longer breaks the command, and it reads the bundle version from
  `AutoRenewConstants.version` instead of repeating it.
- `autorenew doctor` lists devices once rather than twice.

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
