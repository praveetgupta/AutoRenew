# AutoRenew

[![CI](https://github.com/praveetgupta/AutoRenew/actions/workflows/ci.yml/badge.svg)](https://github.com/praveetgupta/AutoRenew/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](#requirements)

A macOS menu-bar app that keeps apps you sideloaded with a **free Apple ID** from expiring. It watches the 7-day clock on each app you register, and before that clock runs out it rebuilds the app from source and reinstalls it on your iPhone — over USB or Wi-Fi, without opening Xcode.

App data survives the refresh: same bundle ID and same signing team means iOS treats it as an upgrade install, not a fresh one.

<!-- Add a menu-bar screenshot here once you have one:
![AutoRenew menu bar](docs/screenshot.png)
-->

## The problem

A free Apple developer account signs apps with a certificate that dies after **7 days**. On day 8 the app on your phone stops launching. The only fix is to re-sign and reinstall it — which normally means remembering to open Xcode and hit Run every week, for every app.

iOS cannot fix this by itself: no app on the device is allowed to re-sign another app. That is why AltStore, SideStore and every other tool in this space need a paired computer. AutoRenew is the same idea, narrowed to one case — apps whose **Xcode project you own** — which lets it skip IPA juggling and just rebuild from source.

## How it works

Every 15 minutes, plus on wake-from-sleep and whenever the menu is opened, AutoRenew:

1. Lists paired devices with `xcrun devicectl list devices --json-output`.
2. If an iPhone is paired but reports `unavailable` (normal for a phone on Wi-Fi), it makes a real connection attempt (`devicectl device info details`). That both tests reachability and wakes the phone's network listener, which is what turns "visible but unavailable" into a working Wi-Fi renewal.
3. For every registered app that is **≥ 5 days** into its 7-day life, it runs `xcodebuild … -allowProvisioningUpdates` against that device, then `xcrun devicectl device install app`.
4. It records the result, updates the menu-bar icon colour, and posts a notification.

If an app hits **6 days** and no iPhone has been reachable, you get a time-sensitive notification telling you to plug the phone in. Builds that fail are retried at most once an hour. Everything lands in `~/Library/Logs/AutoRenew.log`.

Menu-bar icon colour:

| Colour | Meaning |
| --- | --- |
| 🟢 Green | Everything is fresh |
| 🟡 Yellow | Something is due or due soon |
| 🟠 Orange | Something is due and the iPhone is unreachable |
| 🔴 Red | Something has expired |
| ⚪️ Grey | No apps registered yet |

## Requirements

- macOS 13 (Ventura) or later, Apple silicon or Intel.
- **Full Xcode** installed and selected — the Command Line Tools alone are not enough, because AutoRenew builds your projects.
- An Apple ID signed in under *Xcode → Settings → Accounts*. A free (non-paid) account is the whole point, but a paid one works too.
- An iPhone that has been paired with this Mac at least once, with **Developer Mode** on (*Settings → Privacy & Security → Developer Mode*).
- The Xcode projects you want kept alive, checked out on this Mac.

The Mac needs to be awake and reachable by the phone for renewals to happen, so this works best on a machine that stays on — a Mac mini, or a laptop you leave plugged in.

## Install

```bash
git clone https://github.com/praveetgupta/AutoRenew.git
cd AutoRenew
./install.sh
```

`install.sh` builds both binaries in release mode, renders the app icon, assembles `AutoRenew.app`, copies it to `/Applications`, installs the `autorenew` CLI into `/opt/homebrew/bin` (or `/usr/local/bin`), launches the app and runs `autorenew doctor`. Re-run it after pulling changes — the installed copies are copies, not symlinks, so the clone can be moved or cleaned without breaking the command.

The app is signed ad-hoc (`codesign -s -`) because it is built on your own machine. There are no notarized downloads — building from source is the intended path.

## Register your apps

Point AutoRenew at an `.xcodeproj`, an `.xcworkspace`, or any folder containing one:

```bash
autorenew add ~/Projects/MyApp/MyApp.xcodeproj
```

or use the menu-bar icon → **Add App…**. Either way AutoRenew detects the scheme, bundle identifier and development team from the project itself.

Then connect the iPhone and do the first pass by hand:

```bash
autorenew renew --all
```

Finally, turn on **Launch at Login** from the menu-bar icon. From that point renewals are automatic.

## CLI

```
autorenew add <path> [--scheme NAME] [--team TEAMID] [--configuration NAME]
autorenew list                        # registered apps with countdowns
autorenew remove <name>               # unregister (the app on the iPhone is left alone)
autorenew renew [--all] [--app NAME]  # renew now; --all forces every app
autorenew devices                     # what devicectl sees, with reachability probes
autorenew threshold <1-7>             # days used before a renewal fires (default 5)
autorenew doctor                      # check Xcode, devices, signing identity, project paths
autorenew selftest                    # built-in logic tests, no Xcode needed
autorenew version
```

`renew` exits **0** when it renewed or had nothing to do, **1** when a renewal failed, and **2** when
no iPhone was reachable — so a script or cron job can tell "all good" from "go plug your phone in".

Example:

```
$ autorenew list
NAME                     SCHEME             STATE      COUNTDOWN           LAST RESULT
MyApp                    MyApp              fresh      6d 4h left          ✓
Notebook                 Notebook           due soon   1d 9h left          ✓
```

## Living with a free Apple ID

These are Apple's limits, not AutoRenew's:

- **3 apps alive per device per Apple ID**, and **10 new App IDs per week**. If you need more than three, add a second free Apple ID in *Xcode → Settings → Accounts* and split your projects across the two teams. AutoRenew stores the team per app, so mixed teams work fine.
- **Never move an app to a different team.** The bundle would no longer match what is installed, iOS would demand a delete-and-reinstall, and the app's data would go with it.
- **7 days is the hard ceiling.** AutoRenew renews at 5 days by default, leaving two days of slack for a phone that is off, away, or asleep. `autorenew threshold` moves that line.
- Signing sessions expire. If builds start failing with provisioning errors, open *Xcode → Settings → Accounts* and sign in again.

## Where things live

| Path | What |
| --- | --- |
| `~/Library/Application Support/AutoRenew/apps.json` | Registered apps and settings |
| `~/Library/Logs/AutoRenew.log` | Activity log (rotates at 2 MB) |
| `/Applications/AutoRenew.app` | The menu-bar app |
| `/opt/homebrew/bin/autorenew` | Symlink to the CLI |

Nothing is sent anywhere. Everything AutoRenew does is a local `xcodebuild` / `devicectl` call on your own machine.

## Troubleshooting

**`xcrun: error: unable to find utility "devicectl"`**
The Command Line Tools are selected instead of Xcode:
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

**The iPhone shows as `unavailable` over Wi-Fi**
This is `devicectl` reporting that the phone is paired but not answering right now. AutoRenew already probes such phones and uses them if the probe succeeds — `autorenew devices` says which, e.g. `available (paired) · reachable (probed)`. If it keeps failing:

1. Unlock the iPhone once — a sleeping phone drops off the network.
2. Put the Mac and iPhone on the same Wi-Fi (not a guest network, VPN off on both).
3. Connect by USB once, select the iPhone in Finder, tick **Show this iPhone when on Wi-Fi**.
4. Leave the phone on charge. Wi-Fi renewals are most reliable while charging.

Menu-bar icon → **Troubleshoot Device…** runs the same checks and prints what it found.

**Nothing installs, builds fail with provisioning errors**
Run `autorenew doctor`. It checks the developer directory, `xcodebuild`, `devicectl`, Developer Mode on the phone, your `Apple Development` signing identity, and whether every registered project path still exists.

**No notifications**
Allow them for AutoRenew in *System Settings → Notifications*. The app asks on first launch; if you dismissed that prompt, the toggle is there.

**A keychain prompt appears during the first renewal**
Click **Always Allow** — `xcodebuild` needs the signing key.

## Building and testing

```bash
swift build            # both binaries
swift test             # XCTest suite (needs Xcode)
autorenew selftest     # same logic, no XCTest — runs anywhere
```

`selftest` exists so the shipped binary can verify itself on a machine where `swift test` is unavailable. It covers the scheduler maths, countdown formatting, `devicectl` JSON and table parsing, `security find-identity` parsing, build-setting parsing, project location and registry persistence.

## Repo layout

```
Sources/
  AutoRenewCore/     Registry, scheduler, device discovery, renew engine, doctor, selftest
  AutoRenewApp/      Menu-bar app (AppKit, LSUIElement)
  AutoRenewCLI/      autorenew command
Tests/               XCTest suite over AutoRenewCore
install.sh           Build, bundle, install, symlink, launch
make_icon.swift      Renders the app icon and menu-bar glyph at build time
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit together.

## Uninstall

```bash
osascript -e 'quit app "AutoRenew"'
sudo rm -rf /Applications/AutoRenew.app
rm -f /opt/homebrew/bin/autorenew /usr/local/bin/autorenew
rm -rf ~/Library/Application\ Support/AutoRenew ~/Library/Logs/AutoRenew.log
```

The apps on your iPhone and their data are untouched — they will simply start expiring again after 7 days.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Disclaimer

AutoRenew automates the same `xcodebuild` and `devicectl` commands you would run by hand for your own projects on your own device. It does not bypass code signing, patch binaries, or install anything you did not build. Free-account limits (3 apps, 7 days, 10 App IDs per week) are enforced by Apple and cannot be worked around.

## License

[MIT](LICENSE) © 2026 Praveet Gupta
