# Setting up system AutoFill (Mac)

System AutoFill (docs/features/auth-autofill.md → Phase 3) is in the code, but it only goes into a
build when two **Developer ID provisioning profiles** exist. Without them, `make run`, `make build`
and `scripts/release.sh` build exactly what shipped before and print one line:

```
  AutoFill: skipped (no provisioning profiles in ~/.clipboard2/profiles, …)
```

## What needs a profile

| | App `at.softmaze.Clippy` | Extension `at.softmaze.Clippy.autofill` |
|---|---|---|
| AutoFill Credential Provider | yes | yes |
| Keychain Sharing (`XWTH2647FF.at.softmaze.Clippy.shared`) | yes | yes |
| App Sandbox | no (as today) | yes (every extension) |

Entitlements: `Clipboard2/Clipboard2-AutoFill.entitlements` and
`Clipboard2AutoFill/Clipboard2AutoFill-AutoFill.entitlements`. A build with `CLIPBOARD2_AUTOFILL=1` but
without the profiles is killed by macOS at launch, so never set the flag by hand for a build you run.

## 1. Apple Developer portal (once)

[developer.apple.com/account](https://developer.apple.com/account) → **Certificates, Identifiers & Profiles**, team Softmaze (XWTH2647FF).

1. **Identifiers → `at.softmaze.Clippy`** (create it if it isn't there: **+** → App IDs → App, platform
   macOS, Bundle ID *Explicit* `at.softmaze.Clippy`, description "Clipboard2").
   - Capabilities: tick **AutoFill Credential Provider**.
   - If the list shows **Keychain Sharing**, tick it too. (The portal usually doesn't list it: every
     profile then carries `keychain-access-groups = XWTH2647FF.*`, which covers the shared group.)
   - **Save**. If it asks about existing profiles being invalidated, confirm.
2. **Identifiers → +** → App IDs → App, platform **macOS**:
   - Description "Clipboard2 AutoFill", Bundle ID *Explicit* **`at.softmaze.Clippy.autofill`**.
   - Capabilities: **AutoFill Credential Provider** (and Keychain Sharing if listed). **Continue → Register**.
3. **Profiles → +** → under *Distribution* choose **Developer ID** → Continue.
   - Profile type: **Mac**. App ID: **`at.softmaze.Clippy`**. Certificate: your **Developer ID
     Application** certificate (the one `security find-identity -v -p codesigning` lists).
   - Name: `Clipboard2 Developer ID` → **Generate → Download**.
4. Same again for **`at.softmaze.Clippy.autofill`**, name `Clipboard2 AutoFill Developer ID`.

## 2. Put the profiles where the build looks

```
mkdir -p ~/.clipboard2/profiles
mv ~/Downloads/Clipboard2_Developer_ID.provisionprofile          ~/.clipboard2/profiles/Clipboard2.provisionprofile
mv ~/Downloads/Clipboard2_AutoFill_Developer_ID.provisionprofile ~/.clipboard2/profiles/Clipboard2_AutoFill.provisionprofile
scripts/autofill-profiles.sh
```

The file names must be exactly `Clipboard2.provisionprofile` (app) and
`Clipboard2_AutoFill.provisionprofile` (extension); another folder works with
`CLIPBOARD2_PROFILES=/path`. They aren't secrets, but keep them out of the repo.

`scripts/autofill-profiles.sh` checks each profile (right App ID, AutoFill and Keychain Sharing in it,
not expired), copies them to `~/Library/Developer/Xcode/UserData/Provisioning Profiles` and
`~/Library/MobileDevice/Provisioning Profiles`, and prints `AutoFill: on` plus the build settings. If a
profile is wrong it says why and stops the build.

## 3. Build and release

Nothing else changes:

- `make run` / `make build` (with the Developer ID certificate) builds with AutoFill.
- `make release VERSION=x.y.z` → `scripts/make-pkg.sh` builds with `CLIPBOARD2_AUTOFILL=1`, the two
  profile UUIDs and Developer ID signing; Xcode embeds each profile and signs the extension (hardened
  runtime, timestamp), the embed script puts it in `Clipboard2.app/Contents/PlugIns/`, and the whole app
  is notarized and stapled as before. The build stops if the extension is missing or lacks its entitlement.
- The first release with AutoFill writes `scripts/autofill-required` into the release commit. From then
  on a release without the profiles stops instead of shipping: AutoFill builds move secrets, password
  notes and authenticators to the shared (data-protection) Keychain, which a build without AutoFill
  can't read. For the same reason, don't `make run` a build without AutoFill on a Mac that ran one.

What the flag changes (`CLIPBOARD2_AUTOFILL`, default `0`, in `project.yml`): the entitlements files
above, the `AUTOFILL` Swift condition, the extension embedded, `PROVISIONING_PROFILE_SPECIFIER` from
`CLIPBOARD2_APP_PROFILE` / `CLIPBOARD2_AUTOFILL_PROFILE`.

## 4. Check it on a Mac

1. Install the release, open Clipboard2 once (it moves the Keychain items: Console, subsystem
   `at.softmaze.Clippy`, "Moved N Keychain items to the shared Keychain").
2. Settings → Auth shows "Clipboard2 AutoFill is off" → **Open AutoFill Settings** → turn on Clipboard2
   (System Settings → General → AutoFill & Passwords). The line turns to "on".
3. Safari, a login form of a site with a saved password: Clipboard2's suggestion shows; picking it asks
   for Touch ID unless Auth is unlocked in the app.
4. macOS 15+: a one-time-code field on a site with an authenticator offers its code.
5. `codesign -d --entitlements - "/Applications/Clipboard2.app/Contents/PlugIns/Clipboard2 AutoFill.appex"`
   lists the AutoFill entitlement and the shared Keychain group.

## Renewing

Profiles expire with the Developer ID certificate. Regenerate both in the portal (Profiles → the
profile → Edit → Generate), replace the two files and run `scripts/autofill-profiles.sh`. A new
certificate needs new profiles too.
