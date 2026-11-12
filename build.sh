#!/bin/zsh
# Build WhatsApp.app (native, WKWebView). Pakai: ./build.sh [install]
set -euo pipefail
cd "$(dirname "$0")"

APP="build/WhatsappWeb.app"
BUNDLE_ID="local.whatsapp.launcher"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/tmp

echo "→ Compile"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  -framework Cocoa -framework WebKit -framework UserNotifications -framework LocalAuthentication \
  Sources/*.swift -o "$APP/Contents/MacOS/WhatsApp"

echo "→ Icon"
ICONSET=build/tmp/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swiftc -O Tools/make_icon.swift -o build/tmp/make_icon
build/tmp/make_icon build/tmp/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/tmp/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/tmp/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "→ Extensions"
mkdir -p "$APP/Contents/Resources/Extensions"
find Extensions -maxdepth 1 \( -name "*.js" -o -name "*.css" \) -exec cp {} "$APP/Contents/Resources/Extensions/" \;

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WhatsappWeb</string>
  <key>CFBundleDisplayName</key><string>WhatsappWeb</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>WhatsApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSCameraUsageDescription</key><string>WhatsApp memerlukan kamera untuk panggilan video dan foto.</string>
  <key>NSMicrophoneUsageDescription</key><string>WhatsApp memerlukan mikrofon untuk pesan suara dan panggilan.</string>
</dict>
</plist>
PLIST

echo "→ Sign (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
rm -rf build/tmp

echo "✓ $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "install" ]]; then
  rm -rf "/Applications/WhatsappWeb.app" "/Applications/WhatsApp Web.app"  # nama lama ikut dihapus
  cp -R "$APP" /Applications/
  echo "✓ Terpasang di /Applications/WhatsappWeb.app"
fi
