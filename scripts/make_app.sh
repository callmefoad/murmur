#!/bin/bash
# Builds Murmur.app from the SwiftPM release binary.
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="build/Murmur.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Murmur "$APP/Contents/MacOS/Murmur"

# App icon (generated once; rerun scripts/make_icon.swift to change it).
if [ -f "Resources/Murmur.icns" ]; then
    cp Resources/Murmur.icns "$APP/Contents/Resources/Murmur.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>local.murmur</string>
    <key>CFBundleName</key>
    <string>Murmur</string>
    <key>CFBundleExecutable</key>
    <string>Murmur</string>
    <key>CFBundleIconFile</key>
    <string>Murmur</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Murmur records your voice while you hold the dictation key so it can transcribe it on-device.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Murmur transcribes your speech using macOS's on-device speech recognition. Audio never leaves this Mac.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Local build — no data leaves this Mac.</string>
</dict>
</plist>
PLIST

# Prefer the stable local identity (keeps macOS permission grants valid
# across rebuilds); fall back to ad-hoc.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Murmur Dev"; then
    codesign --force --sign "Murmur Dev" "$APP"
    echo "Signed with 'Murmur Dev'."
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "WhisperFlow Dev"; then
    codesign --force --sign "WhisperFlow Dev" "$APP"
    echo "Signed with legacy identity 'WhisperFlow Dev' to preserve existing permission grants (Accessibility, Microphone). Run scripts/make_signing_cert.sh to create the new 'Murmur Dev' identity — note this will require re-granting permissions."
else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc (run scripts/make_signing_cert.sh for a stable identity)."
fi

echo "Built $APP"
