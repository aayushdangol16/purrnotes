#!/bin/bash
# Builds PurrNotes.app next to this script. Needs only the Xcode Command Line Tools.
#   ./build.sh          build the app
#   ./build.sh run      build, then launch it
set -euo pipefail
cd "$(dirname "$0")"

APP="PurrNotes.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PurrNotes"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PurrNotes"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The icon is drawn by the app itself, so there are no image assets to keep in sync.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
"$BIN" --export-iconset "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# Sign with a local, self-made certificate so macOS recognises PurrNotes as the
# same app after every rebuild. Permissions such as Accessibility (needed for
# Workstation full screen) are then kept instead of silently resetting.
# The certificate lives in .signing/ (git-ignored), in its own keychain file;
# the login keychain and system trust settings are not touched.
# Falls back to ad-hoc signing if anything here fails.
SIGN_DIR="$(pwd)/.signing"
KEYCHAIN="$SIGN_DIR/purrnotes-signing.keychain-db"
KEYCHAIN_PASS="purrnotes-local"   # only protects this local signing key
IDENTITY="PurrNotes Local Signing"

make_identity() {
    mkdir -p "$SIGN_DIR"
    local tmp; tmp="$(mktemp -d)"
    cat > "$tmp/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = PurrNotes Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
    # -legacy: the keychain can't read OpenSSL 3's default .p12 format.
    openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$IDENTITY" \
        -out "$tmp/id.p12" -passout pass:"$KEYCHAIN_PASS" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null &&
    security set-keychain-settings "$KEYCHAIN" &&
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" &&
    security import "$tmp/id.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASS" -T /usr/bin/codesign >/dev/null &&
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1
    local status=$?
    rm -rf "$tmp"
    return $status
}

signed=0
if [[ -f "$KEYCHAIN" ]] || make_identity; then
    if security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" 2>/dev/null &&
       codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
        signed=1
    fi
fi
if [[ $signed == 0 ]]; then
    echo "note: local certificate signing failed; using ad-hoc signing (permissions reset on each rebuild)"
    codesign --force --sign - "$APP" >/dev/null 2>&1
fi

echo "Built $(pwd)/$APP"
if [[ "${1:-}" == "run" ]]; then
    open "$APP"
fi
