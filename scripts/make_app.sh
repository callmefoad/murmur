#!/bin/bash
# Builds Murmur.app from the SwiftPM release binary.
#
# Signing: hardened runtime + entitlements whenever a usable identity exists
# (stable local identities preferred so macOS permission grants survive
# rebuilds); falls back to the previous plain ad-hoc signature otherwise.
#
# Notarization (opt-in, requires a Developer ID identity):
#   NOTARY_PROFILE                          — keychain profile created via
#                                             `xcrun notarytool store-credentials`
#   or APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID
# Any notarization failure prints a warning and the script still exits 0,
# leaving the hardened-runtime-signed app in place.
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="build/Murmur.app"
ENTITLEMENTS="Resources/Murmur.entitlements"
rm -rf "$APP" build/Murmur.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Murmur "$APP/Contents/MacOS/Murmur"

# App icon (generated once; rerun scripts/make_icon.swift to change it).
if [ -f "Resources/Murmur.icns" ]; then
    cp Resources/Murmur.icns "$APP/Contents/Resources/Murmur.icns"
fi

# --- Version resolution -----------------------------------------------------
# CFBundleShortVersionString:
#   1. MURMUR_VERSION env override
#   2. nearest git tag, leading "v" stripped
#   3. default "1.0"
# CFBundleVersion: MURMUR_BUILD_NUMBER env → git commit count → "1".
if [ -n "${MURMUR_VERSION:-}" ]; then
    VERSION="$MURMUR_VERSION"
elif VERSION_TAG=$(git describe --tags --abbrev=0 2>/dev/null); then
    VERSION="${VERSION_TAG#v}"
else
    VERSION="1.0"
fi

if [ -n "${MURMUR_BUILD_NUMBER:-}" ]; then
    BUILD_NUMBER="$MURMUR_BUILD_NUMBER"
elif BUILD_FROM_GIT=$(git rev-list --count HEAD 2>/dev/null); then
    BUILD_NUMBER="$BUILD_FROM_GIT"
else
    BUILD_NUMBER="1"
fi

echo "Version: $VERSION (build $BUILD_NUMBER)"

cat > "$APP/Contents/Info.plist" <<PLIST
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
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Murmur records your voice while you hold the dictation key so it can transcribe it on-device.</string>
    <key>NSContactsUsageDescription</key>
    <string>Murmur uses a contact name only after you approve a voice command, so it can open the right Messages conversation.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Murmur transcribes your speech using macOS's on-device speech recognition. Audio never leaves this Mac.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Local build — no data leaves this Mac.</string>
</dict>
</plist>
PLIST

# --- Signing -----------------------------------------------------------------
# Identity resolution order:
#   1. MURMUR_SIGN_IDENTITY env override
#   2. "Murmur Dev"        (current stable local identity)
#   3. "WhisperFlow Dev"   (legacy stable local identity)
#   4. first "Developer ID Application:" identity in the keychain
#   5. ad-hoc fallback (previous behavior)
IDENTITY=""
if [ -n "${MURMUR_SIGN_IDENTITY:-}" ]; then
    IDENTITY="$MURMUR_SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q '"Murmur Dev"'; then
    IDENTITY="Murmur Dev"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q '"WhisperFlow Dev"'; then
    IDENTITY="WhisperFlow Dev"
elif DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep '"Developer ID Application:' | head -1 | awk '{print $2}') && [ -n "$DEV_ID" ]; then
    IDENTITY="$DEV_ID"
fi

NOTARIZABLE=false
if [ -n "$IDENTITY" ]; then
    EXTRA_ARGS=(--options runtime --entitlements "$ENTITLEMENTS")
    case "$IDENTITY" in
        "Developer ID Application":*) EXTRA_ARGS+=(--timestamp); NOTARIZABLE=true ;;
    esac
    if codesign --force "${EXTRA_ARGS[@]}" --sign "$IDENTITY" "$APP"; then
        echo "Signed with '$IDENTITY' (hardened runtime)."
    else
        # Hardened-runtime signing failed → previous ad-hoc behavior.
        echo "WARNING: hardened-runtime signing with '$IDENTITY' failed; falling back to ad-hoc." >&2
        codesign --force --sign - "$APP"
        echo "Signed ad-hoc (hardened runtime NOT applied)."
    fi
else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc (no codesigning identity found — run scripts/make_signing_cert.sh for a stable identity)."
fi

# --- Post-build verification --------------------------------------------------
VERIFY_OUTPUT=$(codesign --verify --deep --strict "$APP" 2>&1) \
    && echo "codesign verify: OK" \
    || { echo "WARNING: codesign verify failed: $VERIFY_OUTPUT" >&2; exit 1; }

FLAGS_LINE=$(codesign -dv "$APP" 2>&1 | grep -i 'flags' || true)
echo "codesign flags: ${FLAGS_LINE:-<none>}"
case "$FLAGS_LINE" in
    *runtime*) echo "Runtime hardening: APPLIED" ;;
    *)         echo "Runtime hardening: NOT applied" ;;
esac

# --- Notarization (opt-in via environment) ------------------------------------
if $NOTARIZABLE; then
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        SUBMIT_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
        SUBMIT_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
    else
        SUBMIT_ARGS=()
    fi

    if [ ${#SUBMIT_ARGS[@]} -gt 0 ]; then
        echo "Submitting for notarization…"
        if ditto -c -k --keepParent "$APP" build/Murmur.zip \
            && xcrun notarytool submit build/Murmur.zip "${SUBMIT_ARGS[@]}" --wait; then
            if xcrun stapler staple "$APP"; then
                echo "Notarized and stapled."
            else
                echo "WARNING: stapling failed — app is Developer-ID-signed but un-notarized." >&2
            fi
        else
            echo "WARNING: notarization submission failed — continuing with signed-but-un-notarized app." >&2
        fi
    else
        echo "Developer ID signature present but no notarization credentials set (NOTARY_PROFILE or APPLE_ID/APPLE_APP_SPECIFIC_PASSWORD/APPLE_TEAM_ID); skipping notarization."
    fi
fi

# --- Seamless swap -------------------------------------------------------------
# Replace any running Murmur with the freshly built bundle so updates are
# live the moment the build finishes. Quitting gracefully first lets
# applicationWillTerminate flush pending history/stats writes.
# Opt out with MURMUR_NORESTART=1.
if [ -n "${MURMUR_NORESTART:-}" ]; then
    echo "MURMUR_NORESTART set — leaving any running instance alone."
else
    if pgrep -xq Murmur; then
        echo "Restarting running Murmur with the new build…"
        # Try a quick graceful quit (lets pending learning/stats writes flush),
        # then hard-kill without ceremony — speed beats politeness here.
        osascript -e 'tell application id "local.murmur" to quit' >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5; do
            pgrep -xq Murmur || break
            sleep 0.2
        done
        if pgrep -xq Murmur; then
            pkill -9 -x Murmur || true
            sleep 0.5
        fi
    fi
    open "$APP"
    echo "Launched $APP"
fi

echo "Built $APP"
