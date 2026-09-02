# Contributing

Thanks for taking a look. AutoRenew is small and deliberately dependency-free, so most changes are
easy to review.

## Getting set up

```bash
git clone https://github.com/praveetgupta/AutoRenew.git
cd AutoRenew
swift build
swift test
```

You need full Xcode (not just the Command Line Tools) for `swift test` and for anything that
actually talks to a device. `swift run autorenew-cli selftest` runs the same assertions without
XCTest.

To try the menu-bar app end to end, run `./install.sh` — it builds, bundles, installs to
`/Applications` and launches. Re-running it replaces the installed copy.

## Before opening a pull request

- `swift build` and `swift test` both pass.
- `swift run autorenew-cli selftest` reports no failures.
- New logic that can be tested without a device has a test. Anything that shells out should go
  through `ProcessRunning` so it can be faked — see the existing tests for the pattern.
- Match the surrounding style: no external dependencies, comments that explain *why* rather than
  restating the code.

## Reporting a bug

Please include:

- macOS and Xcode versions
- the output of `autorenew doctor`
- the relevant part of `~/Library/Logs/AutoRenew.log`
- whether the iPhone was on USB or Wi-Fi

Redact bundle identifiers, team IDs and device identifiers if you would rather not share them —
they are rarely needed to reproduce a problem.

## Things that would help

- A real reachability signal for Wi-Fi devices that does not depend on probing.
- Reading the true expiry date out of the built app's `embedded.mobileprovision` instead of
  counting 7 days from the last successful install.
- Watch and iPad targets.
