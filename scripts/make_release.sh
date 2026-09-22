#!/bin/bash
# Builds a Sparkle-ready Murmur release archive and refreshes appcast.xml.
#
# The Sparkle private key is read from the login Keychain by default. CI or a
# second release machine may instead provide MURMUR_SPARKLE_PRIVATE_KEY; it is
# streamed to generate_appcast and is never written into the repository.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-${MURMUR_VERSION:-}}"
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>" >&2
    echo "Example: $0 0.1.0" >&2
    exit 2
fi

RELEASE_TAG="${MURMUR_RELEASE_TAG:-v$VERSION}"
FEED_URL="${MURMUR_SPARKLE_FEED_URL:-https://raw.githubusercontent.com/callmefoad/murmur/main/appcast.xml}"
PRODUCT_URL="${MURMUR_PRODUCT_URL:-https://github.com/callmefoad/murmur}"
DOWNLOAD_PREFIX="${MURMUR_SPARKLE_DOWNLOAD_PREFIX:-https://github.com/callmefoad/murmur/releases/download/$RELEASE_TAG/}"
BUILD_NUMBER="${MURMUR_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
UPDATE_DIR="build/updates"

# External testers need a stable Developer ID signer, and their first install
# must be notarized to pass Gatekeeper. Fail before building or mutating the
# feed if this machine is not ready to distribute.
SIGNING_IDENTITY="${MURMUR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '\"' '/Developer ID Application:/ { print $2; exit }')}"
if [[ "$SIGNING_IDENTITY" != Developer\ ID\ Application:* ]]; then
    echo "ERROR: Set MURMUR_SIGN_IDENTITY to a valid Developer ID Application identity." >&2
    exit 1
fi
if [ -z "${NOTARY_PROFILE:-}" ] && \
   { [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ]; }; then
    echo "ERROR: Configure NOTARY_PROFILE or APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, and APPLE_TEAM_ID." >&2
    exit 1
fi

MURMUR_VERSION="$VERSION" \
MURMUR_BUILD_NUMBER="$BUILD_NUMBER" \
MURMUR_NORESTART=1 \
MURMUR_SIGN_IDENTITY="$SIGNING_IDENTITY" \
MURMUR_REQUIRE_NOTARIZATION=1 \
MURMUR_SPARKLE_FEED_URL="$FEED_URL" \
./scripts/make_app.sh

mkdir -p "$UPDATE_DIR"
cp build/Murmur.zip "$UPDATE_DIR/Murmur-$VERSION.zip"
if [ -f appcast.xml ] && [ ! -f "$UPDATE_DIR/appcast.xml" ]; then
    cp appcast.xml "$UPDATE_DIR/appcast.xml"
fi

if [ -n "${MURMUR_RELEASE_NOTES:-}" ]; then
    printf '%s\n' "$MURMUR_RELEASE_NOTES" > "$UPDATE_DIR/Murmur-$VERSION.md"
fi

GENERATE_APPCAST=$(find .build/artifacts/sparkle -type f -name generate_appcast \
    -perm -111 -print -quit 2>/dev/null || true)
if [ -z "$GENERATE_APPCAST" ]; then
    echo "ERROR: Sparkle generate_appcast was not found. Build Murmur first." >&2
    exit 1
fi

APPCAST_ARGS=(
    --download-url-prefix "$DOWNLOAD_PREFIX"
    --link "$PRODUCT_URL"
)
if [ -n "${MURMUR_SPARKLE_PRIVATE_KEY:-}" ]; then
    printf '%s' "$MURMUR_SPARKLE_PRIVATE_KEY" | \
        "$GENERATE_APPCAST" --ed-key-file - "${APPCAST_ARGS[@]}" "$UPDATE_DIR"
else
    "$GENERATE_APPCAST" "${APPCAST_ARGS[@]}" "$UPDATE_DIR"
fi

cp "$UPDATE_DIR/appcast.xml" appcast.xml
echo "Release archive: $UPDATE_DIR/Murmur-$VERSION.zip"
echo "Appcast: appcast.xml"

if [ "${MURMUR_PUBLISH:-0}" = "1" ]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "ERROR: GitHub CLI is required when MURMUR_PUBLISH=1." >&2
        exit 1
    fi
    RELEASE_NOTES="${MURMUR_RELEASE_NOTES:-Murmur $VERSION}"
    gh release create "$RELEASE_TAG" \
        "$UPDATE_DIR/Murmur-$VERSION.zip" \
        --title "Murmur $VERSION" --notes "$RELEASE_NOTES"
    git add appcast.xml
    git commit -m "Publish Murmur $VERSION update feed" -- appcast.xml
    git push origin HEAD:main
    echo "Published $RELEASE_TAG and pushed the signed update feed."
else
    echo "Set MURMUR_PUBLISH=1 to create the GitHub Release and push the update feed."
fi
