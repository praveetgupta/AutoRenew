#!/bin/bash
# AutoRenew installer — run on the Mac that has Xcode + your Apple ID (the Mac mini).
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> AutoRenew installer"

# 1. Verify Xcode is present and selected
if ! xcrun xcodebuild -version >/dev/null 2>&1; then
  echo "❌ Full Xcode is required (AutoRenew builds your apps with it)."
  echo "   1) Install Xcode from the App Store and open it once"
  echo "   2) sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  echo "   3) Sign in: Xcode → Settings → Accounts (your free Apple ID)"
  echo "   Then re-run: ./install.sh"
  exit 1
fi

# 2. Build release binaries
echo "==> Building (release)…"
swift build -c release --product AutoRenew
swift build -c release --product autorenew-cli

# 3. Assemble the .app bundle
echo "==> Assembling AutoRenew.app…"
APP="dist/AutoRenew.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AutoRenew "$APP/Contents/MacOS/AutoRenew"

# 3b. Render the icons (signature-purple app icon + menu-bar glyph)
echo "==> Rendering icons…"
ICON_DIR="$(mktemp -d)"
trap 'rm -rf "$ICON_DIR"' EXIT
swift make_icon.swift "$ICON_DIR/AppIcon1024.png" "$ICON_DIR/MenuBar.png"
ICONSET="$ICON_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16     "$ICON_DIR/AppIcon1024.png" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     "$ICON_DIR/AppIcon1024.png" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$ICON_DIR/AppIcon1024.png" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     "$ICON_DIR/AppIcon1024.png" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$ICON_DIR/AppIcon1024.png" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   "$ICON_DIR/AppIcon1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ICON_DIR/AppIcon1024.png" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   "$ICON_DIR/AppIcon1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$ICON_DIR/AppIcon1024.png" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$ICON_DIR/AppIcon1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ICON_DIR/MenuBar.png" "$APP/Contents/Resources/MenuBar.png"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AutoRenew</string>
    <key>CFBundleDisplayName</key><string>AutoRenew</string>
    <key>CFBundleIdentifier</key><string>com.autorenew.local</string>
    <key>CFBundleVersion</key><string>1.1.0</string>
    <key>CFBundleShortVersionString</key><string>1.1.0</string>
    <key>CFBundleExecutable</key><string>AutoRenew</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Personal use</string>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"

# 4. Install to /Applications
echo "==> Installing to /Applications…"
# Remove any previous copy first — `cp -R` into an existing directory would nest the
# new bundle inside the old one (which is how "the app icon is missing" happened).
rm -rf /Applications/AutoRenew.app 2>/dev/null || true
if ! cp -R "$APP" /Applications/AutoRenew.app 2>/dev/null; then
  echo "   /Applications needs admin rights — sudo may ask for your password…"
  sudo rm -rf /Applications/AutoRenew.app
  sudo cp -R "$APP" /Applications/AutoRenew.app
fi

# 5. Symlink the CLI
BIN_DIR="/opt/homebrew/bin"
[ -d "$BIN_DIR" ] || BIN_DIR="/usr/local/bin"
mkdir -p "$BIN_DIR" 2>/dev/null || true
if ln -sf "$(pwd)/.build/release/autorenew-cli" "$BIN_DIR/autorenew" 2>/dev/null; then
  echo "   CLI installed: $BIN_DIR/autorenew"
else
  echo "   ⚠️  Could not symlink the CLI to $BIN_DIR (permissions). Run manually:"
  echo "      sudo ln -sf \"$(pwd)/.build/release/autorenew-cli\" \"$BIN_DIR/autorenew\""
fi

# 6. Launch + verify
echo "==> Launching AutoRenew…"
pkill -x AutoRenew 2>/dev/null || true   # a previously running copy would keep serving the old build
sleep 1
open /Applications/AutoRenew.app
sleep 2

echo "==> Doctor:"
"$BIN_DIR/autorenew" doctor || true

echo
echo "✅ AutoRenew is installed and running in your menu bar (⟳ icon)."
echo
echo "Next steps:"
echo "  1) Register each personal app:   autorenew add /path/to/Project.xcodeproj"
echo "     (or use the menu-bar icon → Add App…)"
echo "  2) Connect your iPhone (USB or same Wi-Fi) and run:   autorenew renew --all"
echo "  3) From now on renewals happen automatically before the 7-day expiry."
