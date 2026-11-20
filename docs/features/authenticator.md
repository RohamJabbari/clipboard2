# Authenticator (1.8)

TOTP codes in Clipboard2. Each authenticator has **one owner**. The owner can **transfer** it and **share** it so other people can get codes too. The wire format and server rules are in `docs/sync/PROTOCOL.md`, "Authenticators" and the `otp` payload. Mac and Windows build the same thing.

## Codes
- Implement RFC 6238 TOTP: SHA1/SHA256/SHA512, 6–8 digits, any period (default 30 s).
- Test against the RFC 6238 appendix B vectors.
- The secret is base32. Accept spaces, lower case and missing padding when parsing.
- Only TOTP is in scope. HOTP (counter-based) is out of scope: refuse `otpauth://hotp` with a clear notice.

## Local storage
- Store the payload like secrets are stored: on the Mac in the Keychain (same service conventions as `Secrets.swift`), on Windows in the DPAPI-protected store that secrets use.
- Keep space/ownership metadata next to it.
- Never write the base32 secret to logs, history, previews, Quick Look, AI or backups.
  - Backups: include authenticators only when "Include secrets" is ticked, like secrets. Add an `authenticators` array to `docs/BACKUP-FORMAT.md`.
  - Only the owner's authenticators go into backups. Import creates personal (owned) authenticators.

## Adding one
All three ways end in the same small form: Issuer, Account, plus Advanced (algorithm, digits, period), then Add.
- **Paste or copy an `otpauth://totp/...` URI.**
  - Clipboard capture must recognise it and **never store it as a history item**. It's a secret.
  - Instead, show the HUD/notice "Authenticator link copied" and offer **Add to Authenticator** in the panel, at the top of All, as a one-off suggestion row. It goes away after you add it or press Esc.
- **QR code in a copied image or screenshot.**
  - Mac: Vision `VNDetectBarcodesRequest`.
  - Windows: ZXing.Net (add the NuGet package) or the Windows barcode API if one is available without extra permissions.
  - When a captured image contains an `otpauth://totp` QR, offer the same Add to Authenticator.
  - The image itself is still stored as a normal clip (it's just an image), but mark it Concealed/sensitive the way the app already treats detected secrets, so it doesn't sync to groups by accident.
- **Manual:** **New Authenticator…** in the Saved header's ＋ / New menu, next to New Folder. The form takes Issuer, Account and Secret (base32).

## Where it shows
- **Saved** lists authenticators together with folders, clips, secrets and snippets, newest first. They don't go into folders in v1.
  - The row shows the issuer as the title and the account as the subtitle.
  - It shows the **current code** in large monospaced digits (grouped `123 456`) and a small **countdown ring** that redraws each second while visible.
  - It shows "Shared by ‹owner›" when you aren't the owner, and "Shared with N" when you own it and it's shared.
- **Personal Saved** shows every authenticator you own or that's shared with you. They're personal tools, so a group's Saved doesn't show them.
- **Search** matches issuer and account.
- **Enter pastes the current code.** If fewer than 3 s are left, wait for the next code and paste that instead, and show "Next code…" while waiting.
- **Copy Code** puts the code on the clipboard without recording it in history (mark it transient), and it's cleared after 30 s, like copied secrets.
- The preview pane shows a big code, the countdown, issuer, account, owner and people.

## Actions
- **Everyone:** Paste Code, Copy Code.
- **Owner:**
  - **Rename** (edit issuer/account).
  - **Share…**: a picker of your contacts and members of your groups, deduplicated, excluding people it's already shared with. It shows a one-line warning: "They'll be able to get codes. Removing them later won't erase what they've seen."
  - **People…**: lists who it's shared with, with Remove per person. The notice after removing says: "Removed. To fully revoke, reset 2FA on the site."
  - **Transfer Ownership…**: choose one of the people it's shared with. You stay on as someone it's shared with, and the new owner can remove you.
  - **Show Secret / QR**: needs Touch ID / Windows Hello. Shows the base32 secret and a QR code to move it to a phone app.
  - **Delete**: removes it for everyone. Use an inline confirm in the panel (the same pattern as other destructive panel actions), not a modal.
- **Someone it's shared with:** **Leave**. It's removed from your list.
- Hide actions the server would refuse. Don't let someone try them and then show a warning.

## Sync
- List spaces with `?include=direct,authenticator`.
- Creating an authenticator:
  1. `POST /v1/authenticators` with a fresh SK wrapped to yourself.
  2. Push the single `otp` item.
- Sharing: `GET /v1/users/id/:uid` for their public key, `wrapSpaceKey`, then `POST …/members`.
- Transfer, remove, leave and delete use the matching routes.
- Pull `otp` items like secrets.
- When an authenticator space disappears from `GET /v1/spaces` (you were removed, it was deleted, or you left), delete it locally.
- Older clients ignore `authenticator` spaces, because they don't ask for them.
- Reuse the existing space/key/item machinery.

## Security notes for the UI
- A one-time tip on the first add, inline rather than a dialog: "Keep your most important 2FA codes on your phone too. Clipboard2 is convenient, but it puts the password and the code in one place."

## Not in scope
HOTP, Steam codes, import from Google Authenticator export QR (`otpauth-migration://`), Apple Watch, and putting authenticators in folders.
