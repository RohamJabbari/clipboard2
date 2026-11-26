# Auth, autofill and email codes (Mac, 1.11+)

Mac only. Windows later (it needs a browser extension: there's no system autofill to plug into).

Build in phases; each phase ships on its own:
1. The Auth chip and passwords
2. Filling by hand
3. System autofill
4. Email codes

## Phase 1: the Auth chip and passwords

### What Auth lists
- **Passwords** (new): a site or app, a username and a password. It's a secret with two new fields.
- **Secrets:** as today. A secret can be given a site, which turns it into a password with an empty username.
- **Authenticators:** owned and shared, as today. They're no longer listed in Saved.
- **Email codes:** phase 4.
- **Personal info cards:** phase 2.

### Sources
- Everything is grouped by **source**: the registrable domain (`accounts.google.com` and `mail.google.com` → `google.com`). Use the public suffix list, bundled.
- A source row shows its icon (the site's favicon, fetched once and cached; otherwise its first letter) and name, with its items beneath:
  - passwords: username
  - authenticator: live code
  - secrets: name
  - email codes: code + age
- Matching items to a source:
  - **Passwords:** their sites (a password can have several sites, e.g. `google.com`, `youtube.com`).
  - **Authenticators:** the `issuer`, mapped to a domain. A bundled table covers the ~200 common issuers ("Google" → google.com, "GitHub" → github.com). Otherwise, a site the user sets on the authenticator (Edit → Website).
  - **Secrets with no site:** a "No website" group at the end.
- Sorted by most recently used source first, then by name. Search matches source name, site, username, item name and issuer. Never values.
- Selecting an item:
  - The preview shows its fields masked: username, password, site(s), code.
  - Each field has its own Copy button and Fill button. Revealing or copying a password asks for Touch ID, like secrets.
  - Return fills (phase 2) or, until phase 2 ships, pastes the password.

### New and edited passwords
- Auth's header has **+** → New Password… / New Secret… / New Authenticator….
  - The form fields: site(s), username, password (with Generate), notes.
- **Generate:** 20 characters in Apple's style, `xxxxxx-xxxxxx-xxxxxx`, from letters and digits with one uppercase and one digit guaranteed. Options for length and symbols sit behind a disclosure.
- Import: CSV from Apple Passwords, Chrome or 1Password export (`url,username,password,notes`). Settings → Auth → Import…. The file is read once and never kept.

### Sync and storage
- The secret payload gets `username` (string, optional) and `urls` (string array, optional), and the authenticator payload gets `urls`. Document both in `docs/sync/PROTOCOL.md`.
  - Both are part of the fingerprint.
  - Unknown-field rules: older clients must keep fields they don't know when they rewrite a payload. Check the Windows client before shipping: if it drops them, a Windows edit would wipe `username` and `urls`. In that case, ship Windows 1.10.x preserving unknown fields first.
- Storage moves from the login Keychain to the **data protection Keychain** in a shared access group, `XWTH2647FF.at.softmaze.Clippy.shared`, so the autofill extension (phase 3) can read it.
  - **Done in phase 3, AutoFill builds only** (`CLIPBOARD2_AUTOFILL=1`, docs/features/autofill-setup.md). Other builds keep the login Keychain (username and sites in the item's description, notes in a second item). A moved secret keeps its creation date in the description (`created`), since the new item gets a new one and the creation date syncs.
  - Migrate once at launch: copy, verify, then delete the old items.
  - Keep reading the old location if the copy failed.
- Member access is unchanged: groups without Secrets access never see passwords either.

## Phase 2: filling by hand
- **Fill:** from Auth, Return on an item fills the target app's focused field.
  - On a password: if the focused field is a text field and the next field is a secure field, type the username, Tab, then the password. If the focused field is secure, only the password.
  - On an authenticator or email code: the code.
  - Typing uses synthetic key events, not the clipboard, so nothing lands in history.
  - If the target can't take typed input (secure input elsewhere), fall back to a transient paste that is never stored.
- **Suggested for this site:**
  - When the panel opens over a browser, read the page URL: Safari and Chromium browsers expose it through Accessibility (`AXURL` / the address field). Firefox: the window title only, best effort.
  - Auth then shows a top section, "For ‹site›", with that source's items.
  - If nothing matches, the full list shows. The user picks manually, and Fill offers "Remember for ‹site›", which adds the site to that password.
- **The paste icon in text fields** now appears in password fields too. There it lists only Auth items, filtered to the page's site, with **Suggest Strong Password** at the end.
  - Suggest Strong Password:
    - generates a password and fills it
    - fills a second password field on the page as well, if there is one (confirm field)
    - saves a new password for the site, taking the username from the nearest text field above
    - shows a notice: "Saved a password for ‹site›" with Undo
- **Personal info cards** (in Auth, under "Me"): name, email, phone, company, street, postcode, city and country.
  - Several cards are allowed (Work, Home).
  - In a text field, the paste icon guesses the field from its accessibility label, placeholder or identifier (email, name, phone, street, zip, city, country) and offers the matching value first.
  - **Fill Form** fills every field it can recognise in the same web area.
  - The rest of the card's values follow, so anything can be picked manually.

## Phase 3: system autofill (passwords and codes)
- An AutoFill **credential provider extension**, "Clipboard2", provides **passwords** and **one-time codes** (macOS 15+). Clipboard2 then appears in the system autofill suggestions in Safari, Chrome and apps, next to or instead of Apple Passwords.
- Register credential identities with `ASCredentialIdentityStore`:
  - every password (site + username)
  - authenticators and email codes as one-time code identities for their source's domain
  - Update them on every change and on sync.
- Filling from the system UI asks for Touch ID inside the extension, unless the app's unlock window is still open.
- Settings → Auth shows whether Clipboard2 is enabled as an autofill provider. If it isn't, it gives one line and **Open AutoFill Settings** (System Settings → General → AutoFill & Passwords). No dialogs.
- **Checked:** Developer ID supports the AutoFill Credential Provider, Keychain Sharing and App Groups capabilities, with Developer ID provisioning profiles. Until those exist, builds leave AutoFill out (docs/features/autofill-setup.md).
- How it's built:
  - Target "Clipboard2 AutoFill" (`at.softmaze.Clippy.autofill`), embedded only with `CLIPBOARD2_AUTOFILL=1`. It compiles `Clipboard2/Shared/` and `TOTP.swift` with the app.
  - The app writes an index to the shared Keychain (titles, usernames, registrable domains; never values). The extension matches a site by host suffix against those domains, and reads values only after Touch ID.
  - The unlock window is shared as an end time in the shared Keychain. It only counts while the app runs, and is never trusted beyond a week.
  - Email codes (phase 4) are handed over with `AutoFillIdentities.update(codes:)`, which does nothing without AutoFill.

## Phase 4: email codes
- Settings → Auth → **Email accounts** → Add:
  - **Microsoft** (Outlook, Hotmail, Microsoft 365): OAuth 2 with PKCE in the browser, Graph `Mail.Read`. App registration is free (the owner registers it; the client id is in the build config).
  - **Google** (Gmail): OAuth 2 with PKCE, `gmail.readonly`.
    - The app stays **unverified**: up to 100 users, each sees Google's warning once.
    - The client id is in the build config. The publishing status must be "In production", or tokens expire after 7 days.
  - **Other (IMAP):** email address and app password. The server is guessed from the domain, with presets for Gmail, Yahoo, iCloud, GMX, web.de, AOL and Outlook.com via OAuth only. A server field is available behind "Advanced".
    - The help text says how to make an app password for the chosen provider.
- Several accounts are allowed. Tokens and passwords go in the Keychain.
- **Fetching:**
  - Only new messages from the last 10 minutes, in the inbox (and Gmail's Updates category).
  - Microsoft: delta query every 15 s. Gmail: `history.list` every 15 s. IMAP: IDLE, else every 30 s.
  - The panel being open fetches immediately.
- **What's kept:** only the code, the sender's domain, the account and the time. Never the message body or subject.
  - Codes are kept in memory and in the Keychain for 10 minutes, then deleted.
  - Nothing is synced or sent to the Clipboard2 server.
- **Recognising a code:**
  - The subject and plain-text body are scanned, on device.
  - A 4–8 digit or 6–8 character alphanumeric token near a keyword: code, verification, verify, one-time, OTP, PIN, passcode, security code, Bestätigungscode, Sicherheitscode, Code, Einmalcode, TAN.
  - Exclude amounts, dates, years, phone numbers and order numbers. If there are several candidates, take the one closest to a keyword.
  - Unit tests cover a corpus of ~40 real-shaped samples (Google, Microsoft, Apple, Amazon, banks, German services).
- **Where codes show:**
  - At the top of Auth for 10 minutes, under their source ("Google · 2 min ago").
  - As a one-time code in system autofill (phase 3) and in Fill.
  - A notification "Code from ‹Source›". It never contains the code unless the user turns on "Show codes in notifications".
- **Matching the sender to a source:** the sender's domain (e.g. `accounts.google.com` → google.com, `no-reply@microsoft.com` → microsoft.com).

## Not in scope
- Passkeys.
- Windows.
- Reading SMS codes. macOS already offers those from Messages.
- Sharing passwords with contacts. Group sharing works as for secrets.
