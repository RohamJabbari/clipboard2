# Authenticator (1.8)

TOTP codes in Clipboard2. Each authenticator has **one owner**. The owner can **transfer** it, and can **share** it so other people get codes. They never get the seed: the owner's devices send them pre-computed codes for the next 24 hours. The wire format and server rules are in `docs/sync/PROTOCOL.md`, "Authenticators" and the `otp` payload. Mac and Windows build the same thing.

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
  - **Share…**: a picker of your contacts and members of your groups, deduplicated, excluding people it's already shared with. It sends them codes, never the secret.
  - **People…**: lists who it's shared with, each with "codes until ‹time›" and Remove. The notice after removing says "Removed. Codes they already have work until ‹time›."
  - **Transfer Ownership…**: choose one of the people it's shared with. Its one-line note says "They'll get the secret and own it; you'll get codes like everyone else."
  - **Show Secret / QR**: needs Touch ID / Windows Hello.
  - **Delete**: removes it for everyone. Use an inline confirm.
- **Shared with you:**
  - The row shows the code from the received batch, the countdown, and "Shared by ‹owner›".
  - When fewer than 2 hours of codes are left, the subtitle reads "Codes until ‹time›".
  - When they run out, it reads "No codes, ‹owner›'s devices have been offline", and the code is dashed.
  - Action: **Leave**.
- Hide actions the server would refuse.

## Sync
- List spaces with `?include=direct,authenticator`. Your own authenticators sync across your devices as items.
- Creating an authenticator:
  1. `POST /v1/authenticators`.
  2. Push the `otp` item.
- Sharing: `GET /v1/users/id/:uid` for their public key, then seal and `PUT` the first batch at once.
- Top-ups:
  - On every sync, any owner device tops up each share with fewer than 12 h of codes left, using `GET …/shares`.
  - Build each batch from the current step for 24 h (2 880 codes at 30 s).
- Received codes: on every sync, `GET /v1/shared-codes`.
  - Unseal each batch with your identity key and store the batches locally, protected like secrets.
  - Drop authenticators that aren't listed anymore.
- Transfer: wrap the space key to the new owner, then `POST …/transfer`. After that, the old owner's devices drop their copy of the seed and show it as shared with them.
- Older clients ignore all of this.

## Security notes for the UI
- A one-time tip on the first add, inline rather than a dialog: "Keep your most important 2FA codes on your phone too. Clipboard2 is convenient, but it puts the password and the code in one place."

## Not in scope
HOTP, Steam codes, import from Google Authenticator export QR (`otpauth-migration://`), Apple Watch, and putting authenticators in folders.
