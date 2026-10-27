#!/bin/bash
# Signs the Windows update feed with the offline Ed25519 key in your Keychain, the way release.sh signs
# Sparkle updates for the Mac. Installed Windows apps refuse any feed without this signature.
#
#   scripts/sign-windows-feed.sh --key            create the key if needed and print its public key
#   scripts/sign-windows-feed.sh --check          check the committed app (HEAD) embeds that key
#   scripts/sign-windows-feed.sh [--wait] 1.4.0   sign the feed CI published for windows-v1.4.0
#                                                 (--wait: first wait for that GitHub build to finish;
#                                                  make windows-release does this)
# Signing:
# 1. downloads releases.win.json and its packages from the windows-latest release
# 2. checks the feed lists the version, and that every package matches its size, SHA-256 and SHA-1
# 3. checks the app at windows-v<version> embeds this key (UpdateService.FeedPublicKey)
# 4. signs the exact feed bytes and uploads releases.win.json.sig to the same release
# 5. checks the feed didn't change meanwhile
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="RohamJabbari/clipboard2-macOS"
RELEASE=windows-latest
ACCOUNT=at.softmaze.Clipboard2.windows-feed   # its own Keychain entry, separate from the Mac's Sparkle key
SERVICES=windows/src/Clipboard2.App/Platform/Services.cs

WAIT=0
[[ "${1:-}" == "--wait" ]] && { WAIT=1; shift; }
ARG="${1:?usage: scripts/sign-windows-feed.sh --key | [--wait] <version>}"

BIN=""
for dir in build/SourcePackages/artifacts/sparkle/Sparkle/bin build-dev/SourcePackages/artifacts/sparkle/Sparkle/bin; do
  [[ -x "$dir/sign_update" ]] && { BIN="$dir"; break; }
done
[[ -n "$BIN" ]] || { echo "Sparkle's tools aren't there yet: run 'make build' once."; exit 1; }

# The public key; generate_keys creates the key pair in the login Keychain the first time.
public_key() {
  local key
  if ! key=$("$BIN/generate_keys" --account "$ACCOUNT" -p 2>/dev/null); then
    echo "▸ No Windows feed key in your Keychain yet: creating one (account $ACCOUNT)." >&2
    "$BIN/generate_keys" --account "$ACCOUNT" >/dev/null
    key=$("$BIN/generate_keys" --account "$ACCOUNT" -p)
  fi
  printf '%s' "$key" | tail -1 | tr -d '[:space:]'
}

PUBLIC=$(public_key)
if [[ "$ARG" == "--key" ]]; then
  echo "Windows update feed public key (paste into $SERVICES as FeedPublicKey):"
  echo "$PUBLIC"
  exit 0
fi
if [[ "$ARG" == "--check" ]]; then VERSION=""; TAG=HEAD; else VERSION="$ARG"; TAG="windows-v$VERSION"; fi
echo "▸ Feed key: $PUBLIC"

EMBEDDED=$(git show "$TAG:$SERVICES" 2>/dev/null | sed -n 's/.*const string FeedPublicKey = "\([^"]*\)";.*/\1/p')
if [[ "$EMBEDDED" != "$PUBLIC" ]]; then
  echo "✗ $TAG doesn't embed this key, so its installs couldn't verify the feed. Set in $SERVICES:"
  echo "      public const string FeedPublicKey = \"$PUBLIC\";"
  echo "  and commit it before releasing."
  exit 1
fi
[[ "$ARG" == "--check" ]] && { echo "✓ The app embeds the feed key."; exit 0; }

if [[ $WAIT == 1 ]]; then
  echo "▸ Waiting for the GitHub build of $TAG…"
  RUN=""
  for _ in $(seq 1 30); do
    RUN=$(gh run list -R "$REPO" --workflow windows.yml --branch "$TAG" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
    [[ -n "$RUN" ]] && break
    sleep 10
  done
  [[ -n "$RUN" ]] || { echo "✗ No GitHub build found for $TAG."; exit 1; }
  gh run watch "$RUN" -R "$REPO" --exit-status >/dev/null || { echo "✗ The GitHub build failed: gh run view $RUN -R $REPO"; exit 1; }
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/feed"
gh release download "$RELEASE" -R "$REPO" -p releases.win.json -D "$WORK/feed"
FEED="$WORK/feed/releases.win.json"

# name, SHA-256, SHA-1, size per package; refuses odd names and a feed without this version.
python3 -I - "$FEED" "$VERSION" > "$WORK/assets.tsv" <<'PY'
import json, re, sys
feed = json.load(open(sys.argv[1], encoding="utf-8-sig"))
assets = feed.get("Assets") or []
if not any(a.get("Version") == sys.argv[2] for a in assets):
    sys.exit(f"✗ The feed doesn't list version {sys.argv[2]} (yet?).")
for a in assets:
    name = a.get("FileName") or ""
    if not re.fullmatch(r"[A-Za-z0-9._-]+\.nupkg", name):
        sys.exit(f"✗ Odd package name in the feed: {name!r}")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", a.get("SHA256") or ""):
        sys.exit(f"✗ {name} has no SHA-256 in the feed; the app would refuse it.")
    print(name, a["SHA256"].lower(), (a.get("SHA1") or "").lower(), a.get("Size") or "", sep="\t")
PY

while IFS=$'\t' read -r NAME SHA256 SHA1 SIZE; do
  gh release download "$RELEASE" -R "$REPO" -p "$NAME" -D "$WORK" --clobber < /dev/null
  FILE="$WORK/$NAME"
  [[ "$(shasum -a 256 "$FILE" | cut -d' ' -f1)" == "$SHA256" ]] || { echo "✗ $NAME doesn't match its SHA-256 in the feed."; exit 1; }
  [[ -z "$SHA1" || "$(shasum -a 1 "$FILE" | cut -d' ' -f1)" == "$SHA1" ]] || { echo "✗ $NAME doesn't match its SHA-1 in the feed."; exit 1; }
  [[ -z "$SIZE" || "$(stat -f%z "$FILE")" == "$SIZE" ]] || { echo "✗ $NAME isn't $SIZE bytes."; exit 1; }
  echo "  ✓ $NAME"
done < "$WORK/assets.tsv"

# Signed as an opaque file (sign_update treats some extensions specially): Ed25519 over the exact bytes.
cp "$FEED" "$WORK/feed.bin"
SIGNATURE=$("$BIN/sign_update" --account "$ACCOUNT" -p "$WORK/feed.bin" | tr -d '[:space:]')
"$BIN/sign_update" --account "$ACCOUNT" --verify "$WORK/feed.bin" "$SIGNATURE" >/dev/null
printf '%s\n' "$SIGNATURE" > "$WORK/releases.win.json.sig"
gh release upload "$RELEASE" "$WORK/releases.win.json.sig" -R "$REPO" --clobber

# A feed replaced while this ran would now carry a signature that doesn't match it: say so.
gh release download "$RELEASE" -R "$REPO" -p releases.win.json -O "$WORK/check.json" --clobber
if ! cmp -s "$FEED" "$WORK/check.json"; then
  gh release delete-asset "$RELEASE" releases.win.json.sig -R "$REPO" -y || true
  echo "✗ The feed changed while it was being signed; run this again."
  exit 1
fi
echo "✓ Signed the Windows update feed for $VERSION. Installed copies update within the hour."
