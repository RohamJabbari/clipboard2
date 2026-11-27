# iOS app (first version)

An iPhone and iPad companion to the Mac app: what you copy on the Mac is on your phone, what you
share on the phone is on the Mac, and Auth's passwords and codes are a tap away. iOS 17+, SwiftUI,
same repo and xcodegen project.

## Scope

| Area | Status |
|---|---|
| Shared code with the Mac app (`Core/`) | Done |
| Copies (history), Saved (folders), Auth (read + copy), Settings | Done |
| Sign-in with email and password, sign-in screen behind a passwordless protocol | Done (passwordless is a stub) |
| Sync: personal space (clips, folders, secrets), authenticator spaces, shared codes | Done, push of clips only |
| Share extension "Share to Clipboard2" (text, links, images, files; optional Save with label and folder) | Done |
| SMS codes: "Save Sign-in Code" App Intent + Settings → Set up SMS codes | Done |
| Groups, contacts, snippets, editing passwords and authenticators, AutoFill | Next |

## Layout

```
Core/                     Compiled by the Mac app, the iOS app and the share extension
  Sync/                   SyncCrypto, SyncAPI, SyncPayload, SyncConfig (unchanged, moved from Clipboard2/Sync)
  Auth/                   TOTP, CodeBatch, SecretExtras, public suffix list, AuthSource, IssuerDomains
  Codes/                  EmailCodeExtractor, SMSCodeExtractor + SMSOriginMatcher (new)
  Clips/                  ClipKind, ContentHasher, ImageProcessor, TextPreview
  Support/Log.swift
iOS/App/                  "Clipboard2 iOS" target: SwiftUI app, AppModel, App Intent
iOS/Shared/               App + share extension: store, session, sync client, importers
iOS/ShareExtension/       "Clipboard2 Share" target
iOS/Tests/                "Clipboard2 iOS Tests" (Swift Testing, Simulator)
```

The Mac app compiles `Core/` exactly as before; only Mac-specific mappings (payloads to and from
SwiftData models, `AuthSource.of(SecretRef)`, `CodeBatch.make(for: Authenticator)`) stayed in
`Clipboard2/`. The Mac suite is unchanged and green.

## How it works

### Storage
- **Clips and folders:** one JSON file (`Items.json`) in the App Group container, read and written
  under `NSFileCoordinator` so the app and the share extension never overwrite each other. File
  protection: complete until first unlock. Local history is capped at 1000 items (saved ones kept).
- **Images and files:** decrypted blobs in `Blobs/` (by blob id), shared files in `Files/<item id>/`.
  Thumbnails of the newest 60 image clips are fetched on each sync; full images and files on copy.
- **Session** (token, account key, identity key, space-key pins): Keychain, data-protection keychain,
  `AfterFirstUnlockThisDeviceOnly`, in the shared group `<TEAM>.at.softmaze.Clippy.ios.shared` so the
  share extension can push.
- **Secrets, passwords, authenticator seeds, shared code batches:** the app's own Keychain (not shared
  with the extension).
- **SMS codes:** the app's own Keychain, deleted after 10 minutes.

### Sync (`iOS/Shared/MobileSync.swift`)
Follows PROTOCOL.md → Client sync rules on the shared `SyncAPI`/`SyncCrypto`/payloads:
- Pulls the personal space and every authenticator space (`changes` paging, `resetRequired`
  restart with `full=1`), then `GET /v1/shared-codes`.
- Applies upserts last-write-wins on `updatedAt`; rejects payloads whose `rev` doesn't match
  `updatedAt`; `user` tombstones delete; `trimmed` ones stop tracking a personal history item.
- Space keys are pinned (SHA-256 per space id, like the Mac's `spaceKeyPins`): a swapped key is refused.
- Pushes clips created or changed here (share, paste, save/unsave, label, copy), uploading images,
  thumbnails and files as blobs first; deletes as tombstones. `409` applies the server's version.
- Content hashes, previews and payload fields are made the same way as on the Mac, so sharing a text
  the Mac already has merges into one item.
- Runs at launch, when the app comes to the front, every 20 s while it's in front, on pull-to-refresh
  and after each local change. No background refresh yet.
- `401 unauthenticated` marks the session expired; Copies and Settings ask to sign in again.

### Sign-in
`PasswordSignIn` is the existing flow (prelogin → PBKDF2 → login → unwrap AK and identity key), with
the same KDF safety checks as the Mac. The screen also shows **Approve on My Mac Instead**, wired to
the `PasswordlessSignIn` protocol (`begin` → `ApprovalRequest` with a match code → `waitForApproval`
→ `MobileSession`). `PasswordlessSignInStub` reports it unavailable, so the button is disabled with a
"Coming soon" note. When docs/features/passwordless.md lands, implement the protocol and pass it to
`AppModel(passwordless:)`; `AppModel.finishSignIn(_:)` already adopts the resulting session.

### Share extension
Activates for text, one web URL, up to 10 images/movies/files. Each text, link or image becomes one
clip; files together become one file clip (at most 10, each ≤ 100 MB sealed). Options: **Save**, a
label and a Saved folder. The clip is written to the shared store first, then pushed directly
(up to 15 s); anything unfinished is pushed by the app next time. Signed out, clips stay on the
device and join the personal space at sign-in. Folders (directories) aren't supported yet.

### SMS codes
iOS apps can't read text messages. Instead:

1. **App Intent "Save Sign-in Code"** (`SaveSignInCodeIntent`), inputs: message text and sender.
   It's an App Shortcut (`Clipboard2Shortcuts`), so the action is in Shortcuts as soon as the app is
   installed, with nothing to import. It runs in the background and returns the code (empty if none).
2. **Extraction** (`Core/Codes/SMSCodeExtractor.swift`): origin-bound codes (`@site.com #123456`,
   last line) → Google's `G-123456` → the Mac's email code rules → the same with hyphenated keywords
   split (`Freigabe-TAN`) → SMS words near a number (`log in`, `Anmeldung`, `security`…).
3. **Which site** (`SMSOriginMatcher`), in order: origin-bound domain → a sender the user assigned
   before → the sender (email address of an iMessage, known short codes such as 22000 → Google,
   sender names, the Mac's issuer table) → `G-` prefix → a domain written in the message → a known
   service named with a capital ("PayPal", "eBay"; everyday words like "Target" are ignored) → the
   site last copied from in Auth within 10 minutes (marked "guessed") → none ("From messages").
4. **Stored like email codes:** only code, site, sender and time; on this device; 10 minutes. Shown
   in Auth under the site (sites with a fresh code first), unplaced ones on top under "From messages".
   **Assign to Site…** on a code fixes it and remembers that sender.

**Setup, honestly:** iOS has no API for an app to create a personal automation, and Shortcuts has no
documented URL for the Automation tab or a new automation (its URL scheme opens the app, a named
shortcut, or a new empty shortcut). An iCloud shortcut link only adds a shortcut, not an automation,
and isn't needed because the action ships with the app. So:
- **One tap:** Settings → **Set up SMS codes** → **Open Shortcuts** (`shortcuts://`).
- **Not one tap (six steps, once, shown inline):** Automation → + → Message (Any Sender) → Run
  Immediately, Notify When Run off → New Blank Automation → Add Action "Save Sign-in Code" → Message =
  Shortcut Input, Sender = Shortcut Input → Sender → Done.
- The setup screen has a test box: paste a message and see the code and site it would save.
- Note: iOS already suggests SMS codes above the keyboard. This feature puts them in Auth under their
  site; it becomes much more useful once codes sync to the Mac (see Next).

## Signing and capabilities

- Developer ID can't sign iOS. The iOS targets use **Apple Development, automatic signing, team
  XWTH2647FF**. Simulator builds are signed to run locally and need no provisioning profile
  (`make ios-build`, `make ios-test`). The Mac targets and `make build` / `make release` are unchanged:
  they only build the `Clipboard2` scheme, which doesn't include the iOS targets.
- Bundle ids: app `at.softmaze.Clippy.ios`, share extension `at.softmaze.Clippy.ios.share`.
- Capabilities (both ids): **App Groups** `group.at.softmaze.Clippy.ios`, **Keychain Sharing**
  `at.softmaze.Clippy.ios.shared`. The entitlements files are generated from project.yml.
- `make ios-build` builds for the Simulator; `make ios-test` runs the tests on `IOS_SIM` (default
  "iPhone 17").

### Owner steps before a device build or TestFlight
1. developer.apple.com → Identifiers: create the App Group `group.at.softmaze.Clippy.ios`.
2. Register App IDs `at.softmaze.Clippy.ios` and `at.softmaze.Clippy.ios.share`, both with
   **App Groups** (that group) and **Keychain Sharing**. (Xcode's automatic signing can do steps 1–2
   when you build to a device while signed in to the team, but creating them explicitly avoids surprises.)
3. App Store Connect → New App: platform iOS, bundle id `at.softmaze.Clippy.ios`, name "Clipboard2"
   (or the store name you want), SKU of your choice.
4. Export compliance: the app uses standard encryption (AES-GCM, P-256, PBKDF2) for end-to-end
   encrypted user data. Answer the questionnaire accordingly; then add `ITSAppUsesNonExemptEncryption`
   to project.yml so uploads stop asking.
5. Privacy: a privacy policy URL, and the App Privacy answers (email address and user content,
   linked to the user, used for app functionality only; content is end-to-end encrypted).
6. Replace the placeholder app icon (iOS/Resources/Assets.xcassets).
7. Archive: `xcodebuild -scheme "Clipboard2 iOS" -destination 'generic/platform=iOS' archive`, or
   Product → Archive in Xcode, then upload to TestFlight.

## Tests

`iOS/Tests` (Simulator):
- `SMSCodeTests`: 25 message samples (Google `G-`, origin-bound, German "Ihr Code lautet", mTAN with
  amount and IBAN, Freigabe-TAN, Raiffeisen/BAWAG/George/DKB, PayPal, Revolut, N26, WhatsApp,
  Microsoft, iMessage from an email address, a learned sender, and non-codes: tracking numbers,
  promo codes, appointments, chat) for the code and the site; reasons in order; sender keys;
  everyday words; abbreviations; the code store's expiry, de-duplication and learning a sender.
- `MobileSyncTests`: pulling sealed items, rollback and `rev` checks, last-write-wins against a
  local change, tombstones, merging duplicates, delete tombstones, password unlock, space-key pins.

Not covered by automated tests: the network round trip against a real server, the share extension
UI and the Shortcuts automation itself (manual, below).

## Next

1. Passwordless sign-in: implement `PasswordlessSignIn` once the protocol lands.
2. Sync SMS codes to the user's Macs (sealed like shared codes, short-lived) so a text on the phone
   fills on the Mac. This is where SMS codes pay off; it needs a protocol addition.
3. Groups and contacts (spaces, Inbox, send to device), snippets.
4. Editing passwords and authenticators, adding authenticators by QR code.
5. AutoFill credential provider extension for passwords and one-time codes.
6. Background refresh (`BGAppRefreshTask`) and push notifications instead of polling.
7. A proper iOS app icon (the current one is the Mac icon cropped and flattened).
8. Large file uploads from the share extension via a background `URLSession`.

## Manual test checklist

1. `make ios-build`, run on a Simulator or device, sign in with a sync account → Copies/Saved/Auth fill.
2. Copy text on the Mac → it appears in Copies within ~20 s while the app is open; tap → pasted on iPhone.
3. Share a Safari link, a photo and a PDF to Clipboard2 (Save on, label, folder) → on the Mac in Saved.
4. Auth: authenticator codes tick; tap a password → Face ID → "Password copied" (expires in 90 s).
5. Settings → Set up SMS codes → follow the steps; send yourself "G-123456 is your Google
   verification code" → Auth shows it under google.com for 10 minutes.
