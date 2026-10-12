#!/bin/bash
# Builds dist/Clipboard2-<version>.pkg — a standard macOS Installer package.
#
# Signing is automatic:
#   • "Developer ID Application" cert present → app signed with it (+ secure timestamp)
#   • "Developer ID Installer" cert present   → package signed with it
#   • NOTARY_PROFILE (default: clippy-notary) stored with `xcrun notarytool store-credentials`
#     → app and package are notarized and stapled, so they open on any Mac without warnings.
# Without those it still builds, but other Macs will show a Gatekeeper warning.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-clipboard2-notary}"
DERIVED=build
STAGE=build/pkg
DIST=dist
APP_NAME=Clipboard2
PKG_ID=at.softmaze.Clippy.pkg

identity() { security find-identity -v ${2:-} | grep -o "\"$1: [^\"]*\"" | head -1 | tr -d '"' || true; }
APP_ID=$(identity "Developer ID Application" "-p codesigning")
INSTALLER_ID=$(identity "Developer ID Installer")
step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

step "Building Release"
xcodegen generate --quiet
SIGN_ARGS=()
if [[ -n "$APP_ID" ]]; then
    echo "  app signing: $APP_ID"
    SIGN_ARGS=(CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=XWTH2647FF CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS=--timestamp)
else
    echo "  app signing: Apple Development (no Developer ID Application certificate found)"
fi
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS' build -quiet ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

# Sparkle's helper tools must carry our Developer ID, hardened runtime and a timestamp to pass
# notarization; re-sign them inside-out, then the app (keeping its entitlements).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -n "$APP_ID" && -d "$SPARKLE" ]]; then
    echo "  re-signing Sparkle helpers"
    for item in "$SPARKLE/Versions/B/XPCServices/Installer.xpc" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
                "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
        [[ -e "$item" ]] && codesign -f -s "$APP_ID" -o runtime --timestamp --preserve-metadata=entitlements "$item" 2>/dev/null
    done
    codesign -f -s "$APP_ID" -o runtime --timestamp --preserve-metadata=entitlements,requirements,flags "$APP"
fi
codesign --verify --strict --deep "$APP"

can_notarize() { [[ -n "$APP_ID" ]] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; }

if [[ -n "$APP_ID" ]] && ! can_notarize; then
    printf '\033[33m  ⚠ No working notarization login (profile "%s"). Run:\n    xcrun notarytool store-credentials %s --apple-id <you> --team-id XWTH2647FF\033[0m\n' "$NOTARY_PROFILE" "$NOTARY_PROFILE"
fi
if can_notarize; then
    step "Notarizing app"
    ditto -c -k --keepParent "$APP" "$DERIVED/$APP_NAME-notarize.zip"
    xcrun notarytool submit "$DERIVED/$APP_NAME-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$DERIVED/$APP_NAME-notarize.zip"
fi

step "Packaging $APP_NAME $VERSION"
rm -rf "$STAGE"
mkdir -p "$STAGE/root/Applications" "$DIST"
ditto "$APP" "$STAGE/root/Applications/$APP_NAME.app"

# Never let Installer "relocate" the app to some other copy it finds on disk.
pkgbuild --analyze --root "$STAGE/root" "$STAGE/component.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$STAGE/component.plist"

pkgbuild --root "$STAGE/root" --component-plist "$STAGE/component.plist" \
    --scripts installer/scripts --identifier "$PKG_ID" --version "$VERSION" \
    --install-location / "$STAGE/$APP_NAME-component.pkg" >/dev/null

cat > "$STAGE/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>$APP_NAME</title>
    <organization>at.softmaze</organization>
    <welcome file="welcome.html" mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <background file="background.png" mime-type="image/png" alignment="bottomleft" scaling="none"/>
    <background-darkAqua file="background.png" mime-type="image/png" alignment="bottomleft" scaling="none"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default"><line choice="$PKG_ID"/></line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$PKG_ID" visible="false"><pkg-ref id="$PKG_ID"/></choice>
    <pkg-ref id="$PKG_ID" version="$VERSION" onConclusion="none">$APP_NAME-component.pkg</pkg-ref>
</installer-gui-script>
XML

OUT="$DIST/$APP_NAME-$VERSION.pkg"
PRODUCT_ARGS=(--distribution "$STAGE/Distribution.xml" --resources installer/resources --package-path "$STAGE")
if [[ -n "$INSTALLER_ID" ]]; then
    echo "  package signing: $INSTALLER_ID"
    PRODUCT_ARGS+=(--sign "$INSTALLER_ID" --timestamp)
else
    echo "  package signing: none (no Developer ID Installer certificate found)"
fi
productbuild "${PRODUCT_ARGS[@]}" "$OUT" >/dev/null

if [[ -n "$INSTALLER_ID" ]] && can_notarize; then
    step "Notarizing package"
    xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT"
fi

step "Done"
echo "  $OUT ($(du -h "$OUT" | cut -f1))"
if [[ -z "$APP_ID" || -z "$INSTALLER_ID" ]] || ! can_notarize; then
    echo "  Not notarized — fine on this Mac; other Macs will show a Gatekeeper warning."
    echo "  See README → Distribution to set up Developer ID signing."
fi
