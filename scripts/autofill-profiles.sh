#!/bin/bash
# System AutoFill needs two Developer ID provisioning profiles (docs/features/autofill-setup.md):
#   ~/.clipboard2/profiles/Clipboard2.provisionprofile            (App ID at.softmaze.Clippy)
#   ~/.clipboard2/profiles/Clipboard2_AutoFill.provisionprofile   (App ID at.softmaze.Clippy.autofill)
# (another folder: CLIPBOARD2_PROFILES=/path).
#
# With both there: checks them, installs them where Xcode looks, and prints the xcodebuild
# arguments for an AutoFill build, one per line. Without them: prints nothing, and one line on
# stderr saying AutoFill was skipped. Exits 1 if a profile is there but wrong.
set -euo pipefail

TEAM=XWTH2647FF
DIR="${CLIPBOARD2_PROFILES:-$HOME/.clipboard2/profiles}"
APP_PROFILE="$DIR/Clipboard2.provisionprofile"
EXT_PROFILE="$DIR/Clipboard2_AutoFill.provisionprofile"

if [[ ! -f "$APP_PROFILE" || ! -f "$EXT_PROFILE" ]]; then
    echo "  AutoFill: skipped (no provisioning profiles in $DIR, see docs/features/autofill-setup.md)" >&2
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Decodes a profile, checks it's for this App ID and carries AutoFill, prints its UUID.
check() {
    local file="$1" app_id="$2" plist="$TMP/$(basename "$1").plist"
    security cms -D -i "$file" > "$plist" 2>/dev/null || { echo "  AutoFill: $file isn't a provisioning profile" >&2; exit 1; }
    local got expires
    got=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$plist" 2>/dev/null || true)
    if [[ "$got" != "$TEAM.$app_id" ]]; then
        echo "  AutoFill: $file is for '$got', expected '$TEAM.$app_id'" >&2; exit 1
    fi
    if ! /usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.authentication-services.autofill-credential-provider" "$plist" >/dev/null 2>&1; then
        echo "  AutoFill: $file lacks the AutoFill Credential Provider capability (regenerate it after enabling it)" >&2; exit 1
    fi
    if ! /usr/libexec/PlistBuddy -c "Print :Entitlements:keychain-access-groups" "$plist" >/dev/null 2>&1; then
        echo "  AutoFill: $file lacks Keychain Sharing (regenerate it after enabling it)" >&2; exit 1
    fi
    expires=$(/usr/libexec/PlistBuddy -c "Print :ExpirationDate" "$plist")
    if [[ $(date -j -f "%a %b %d %T %Z %Y" "$expires" +%s 2>/dev/null || echo 9999999999) -lt $(date +%s) ]]; then
        echo "  AutoFill: $file expired ($expires)" >&2; exit 1
    fi
    /usr/libexec/PlistBuddy -c "Print :UUID" "$plist"
}

APP_UUID=$(check "$APP_PROFILE" at.softmaze.Clippy)
EXT_UUID=$(check "$EXT_PROFILE" at.softmaze.Clippy.autofill)

# Where Xcode looks (the first for Xcode 16+, the second for older ones).
for target in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    mkdir -p "$target"
    cp "$APP_PROFILE" "$target/$APP_UUID.provisionprofile"
    cp "$EXT_PROFILE" "$target/$EXT_UUID.provisionprofile"
done

echo "  AutoFill: on (profiles $APP_UUID, $EXT_UUID)" >&2
echo "CLIPBOARD2_AUTOFILL=1"
echo "CLIPBOARD2_APP_PROFILE=$APP_UUID"
echo "CLIPBOARD2_AUTOFILL_PROFILE=$EXT_UUID"
