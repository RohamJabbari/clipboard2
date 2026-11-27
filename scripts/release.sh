#!/bin/bash
# Publishes a new version that existing installs pick up within an hour:
#   scripts/release.sh 1.2.0      (or: make release VERSION=1.2.0)
# 1. bumps the version and build number in project.yml
# 2. builds, signs, notarizes and staples the app + installer (make-pkg.sh)
# 3. zips the app for Sparkle and signs it with the EdDSA key in your Keychain
# 4. creates the GitHub release (installer + update zip), then pushes appcast.xml
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
REPO="RohamJabbari/clipboard2-macOS"
APP_NAME=Clipboard2

[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first."; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "v$VERSION already exists."; exit 1; }
# Gmail sign-in needs the client secret, kept out of the public repo (see OAuthClients.plist).
/usr/libexec/PlistBuddy -c "Print :GoogleClientSecret" Clipboard2/Resources/OAuthSecrets.plist 2>/dev/null | grep -q . \
  || { echo "Clipboard2/Resources/OAuthSecrets.plist with GoogleClientSecret is missing; Gmail sign-in would break."; exit 1; }

BUILD=$(( $(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml) + 1 ))
sed -i '' -e "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" \
          -e "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
echo "▸ $APP_NAME $VERSION (build $BUILD)"

# System AutoFill goes in when the two provisioning profiles are in ~/.clipboard2/profiles
# (docs/features/autofill-setup.md). Once a release had it, every later one must: AutoFill builds
# move secrets to the shared Keychain, which builds without it can't read.
AUTOFILL_MARKER=scripts/autofill-required
CLIPBOARD2_REQUIRE_AUTOFILL=$([[ -f "$AUTOFILL_MARKER" ]] && echo 1 || echo 0) scripts/make-pkg.sh

APP="build/Build/Products/Release/$APP_NAME.app"
xcrun stapler validate "$APP" >/dev/null || { echo "The app isn't notarized; refusing to publish an update."; exit 1; }
if [[ -d "$APP/Contents/PlugIns/$APP_NAME AutoFill.appex" && ! -f "$AUTOFILL_MARKER" ]]; then
    echo "This release ships system AutoFill: every later release needs the AutoFill provisioning profiles." > "$AUTOFILL_MARKER"
fi
ZIP="dist/$APP_NAME-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SIGN_UPDATE=""
for dir in build/SourcePackages/artifacts/sparkle/Sparkle/bin build-dev/SourcePackages/artifacts/sparkle/Sparkle/bin .tools/sparkle-bin; do
    [[ -x "$dir/sign_update" ]] && { SIGN_UPDATE="$dir/sign_update"; break; }
done
[[ -n "$SIGN_UPDATE" ]] || { echo "Sparkle's sign_update isn't there: run 'make build' once."; exit 1; }
SIGNATURE=$("$SIGN_UPDATE" --account at.softmaze.Clipboard2 "$ZIP")
URL="https://github.com/$REPO/releases/download/v$VERSION/$APP_NAME-$VERSION.zip"
python3 scripts/appcast.py appcast.xml "$VERSION" "$BUILD" "$URL" "$SIGNATURE"

git add project.yml appcast.xml
[[ -f "$AUTOFILL_MARKER" ]] && git add "$AUTOFILL_MARKER"
git commit -q -m "chore(release): $VERSION"
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"

# Assets first, so the feed never points at a file that isn't there yet… then the feed is live
# because appcast.xml on main was just pushed (raw.githubusercontent.com may cache ~5 min).
gh release create "v$VERSION" "dist/$APP_NAME-$VERSION.pkg" "$ZIP" -R "$REPO" \
    --title "$APP_NAME $VERSION" --generate-notes --verify-tag
# Every version's installer and update zip live on its GitHub release; keep only this one locally.
find dist -name "$APP_NAME-*" ! -name "$APP_NAME-$VERSION.*" -delete
# Clean build: keep Sparkle's tools (sign-windows-feed.sh needs them), drop the rest (rebuilt next time).
rm -rf .tools/sparkle-bin && mkdir -p .tools && cp -R "$(dirname "$SIGN_UPDATE")" .tools/sparkle-bin
rm -rf build build-dev
echo "✓ Released $VERSION — installs update themselves within the hour."
