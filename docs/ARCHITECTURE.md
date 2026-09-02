# Architecture

Three targets sit on top of one library.

```
AutoRenewApp (menu bar)   AutoRenewCLI (autorenew)
             \                   /
              \                 /
               AutoRenewCore (library)
                       |
        xcodebuild · devicectl · security  (via ProcessRunning)
```

Everything that touches the outside world goes through `ProcessRunning`, a protocol with a single
`run(executable:arguments:currentDirectory:timeout:)` method. `RealProcessRunner` is the production
implementation; tests inject their own, which is why the parsing and scheduling logic can be tested
without Xcode, a device, or an Apple ID.

## AutoRenewCore

| File | Responsibility |
| --- | --- |
| `Models.swift` | `AppEntry`, `Settings`, `DeviceInfo`, freshness/countdown maths |
| `Registry.swift` | Reads and writes `~/Library/Application Support/AutoRenew/apps.json` |
| `Scheduler.swift` | Which apps are due, which are urgent, and when to retry a failure |
| `DeviceMonitor.swift` | `devicectl` JSON and table parsing, plus the reachability probe |
| `Discovery.swift` | Scheme listing, build settings, signing identities, project location |
| `RenewEngine.swift` | One app: build with fresh provisioning, locate the product, install it |
| `RenewService.swift` | One pass: pick a device, renew every due app, record results, notify |
| `Doctor.swift` | Environment checks surfaced by both the CLI and the app |
| `SelfTest.swift` | XCTest-free assertions over the pure logic above |
| `Notifier.swift` | `UNUserNotificationCenter` when bundled, log-only otherwise |
| `Logger.swift` | Append-only log with rotation at 2 MB |

## The renewal pass

`RenewService.run(force:only:preFetchedDevices:progress:)` is the single entry point used by the
timer, the menu, and the CLI.

1. **Find a device.** `DeviceWatcher.refresh()` lists paired devices and probes any iPhone that is
   paired but not currently reachable, at most once every 5 minutes per device. iPhones are
   preferred; an iPad is accepted as a fallback; Apple Watches are never targeted.
2. **No device?** Check whether anything is close to expiry (`Scheduler.urgentApps`) and, if so,
   send a time-sensitive notification instead of failing silently.
3. **Pick targets.** A specific app id, or everything (`force`), or `Scheduler.dueApps` — apps that
   have never been renewed, or that have used up `renewThresholdDays` of their 7 days.
4. **Renew each one.** `RenewEngine` runs `xcodebuild build` with `-allowProvisioningUpdates` and
   `-allowProvisioningDeviceRegistration` against `id=<device>`, reads `TARGET_BUILD_DIR` and
   `FULL_PRODUCT_NAME` back out of `-showBuildSettings`, and installs the resulting `.app` with
   `devicectl device install app`.
5. **Record and notify.** Success stamps `lastSuccessfulRefresh`, which is what the 7-day countdown
   is measured from. Failures keep the old timestamp and back off for an hour.

## Device reachability

`devicectl` describes a paired device by `tunnelState`: `connected` for USB and for a live Wi-Fi
tunnel, `disconnected` once that tunnel has dropped, and `unavailable` for a phone that is paired
but not answering. A phone on Wi-Fi spends most of its time in the last two, which is why a bare
`list devices` is not a reliable reachability test.

Only the first word of the state carries meaning, and it is compared exactly. Searching for a
substring instead is a trap: `disconnected` contains `connected`, so a dropped tunnel would read as
reachable and the pass would build against a destination that is not there.

`DeviceWatcher.probe` therefore runs `devicectl device info details --device <id>`, a real
connection attempt. It succeeds surprisingly often against a phone that had just been reported
`unavailable`, and as a side effect it wakes the phone's network listener so the subsequent install
works. `DeviceInfo.probedReachable` records that result and overrides the listed state.

## State

One file, `apps.json`, holds the app list and settings. It is written atomically under an `NSLock`.

The menu-bar app and the CLI are separate processes holding their own `Registry` instance, and the
app runs for weeks at a time. Every read and every write therefore compares the file's modification
date against what is held in memory and re-reads when they differ, so `autorenew add` from a
terminal shows up in the running app's menu, and the app's next save cannot overwrite it. Within a
process the read-modify-write is serialized by the lock; across processes the remaining window is
sub-millisecond and both writers are user-driven.
