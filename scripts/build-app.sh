#!/bin/zsh
# Builds Mylbox.app into ./build and signs it with your Developer ID (falls back to ad-hoc signing).
# Usage: scripts/build-app.sh [--install]   (--install copies the app to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Mylbox
BIN="$(swift build -c release --show-bin-path)/Mylbox"
APP="build/Mylbox.app"
VERSION="0.1.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mylbox"

# Embed llama.cpp and let the executable find it in Contents/Frameworks.
mkdir -p "$APP/Contents/Frameworks"
cp -R "$(dirname "$BIN")/llama.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Mylbox" 2>/dev/null || true
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>mylbox</string>
    <key>CFBundleDisplayName</key><string>mylbox</string>
    <key>CFBundleIdentifier</key><string>ch.mylbox.app</string>
    <key>CFBundleExecutable</key><string>Mylbox</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

IDENTITY="$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Frameworks/llama.framework"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - "$APP/Contents/Frameworks/llama.framework"
    codesign --force --sign - "$APP"
    echo "No Developer ID found, signed ad-hoc."
fi

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/Mylbox.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Mylbox.app"
else
    echo "Built $APP"
fi
