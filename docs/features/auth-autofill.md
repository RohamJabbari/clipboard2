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
- **Generate:** offers two passwords side by side, both 20 characters; the user picks one and nothing is filled before that.
  - **Letters & digits:** Apple's style, `xxxxxx-xxxxxx-xxxxxx`, with one uppercase, one lowercase and one digit guaranteed.
  - **With symbols:** no hyphens, at least one uppercase, lowercase, digit and symbol. Symbols are `!#$%&*+.=?@^_~` only: no quotes, backslash, backtick or space, which commonly break sites and shells.
  - The same two options appear wherever a strong password is suggested (Suggest Strong Password, phase 2).
- Import: CSV from Apple Passwords, Chrome or 1Password export (`url,username,password,notes`). Settings → Auth → Import…. The file is read once and never kept.

### Sync and storage
- The secret payload gets `username` (string, optional) and `urls` (string array, optional), and the authenticator payload gets `urls`. Document both in `docs/sync/PROTOCOL.md`.
  - Both are part of the fingerprint.
  - Unknown-field rules: older clients must keep fields they don't know when they rewrite a payload. Check the Windows client before shipping: if it drops them, a Windows edit would wipe `username` and `urls`. In that case, ship Windows 1.10.x preserving unknown fields first.
- Storage moves from the login Keychain to the **data protection Keychain** in a shared access group, `XWTH2647FF.at.softmaze.Clippy.shared`, so the autofill extension (phase 3) can read it.
  - **TODO: moved to phase 3.** It needs provisioning profiles we don't have yet; phase 1 keeps the login Keychain (username and sites in the item's description, notes in a second item).
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
  - **Storage: local only in this phase.** Cards are one item in the login Keychain on this Mac. They are not a sync payload and don't sync between devices or to groups.

### As built (1.11)
- **Fill:** Return on a password fills it (⌘K → Fill, and Fill in the preview). A plain secret (no site, no username) still pastes, concealed, as before: it may be multi-line. In a text field with no password field after it, Fill types only the username (username-first sign-ins), or the password when there's no username.
  - The focused field's kind comes from `AXSubrole` `AXSecureTextField`; the next field from VoiceOver's text-field search in the web area (`AXUIElementsForSearchPredicate`), else a bounded tree walk.
  - "Secure input elsewhere" is `kCGSSessionSecureInputPID` naming a process other than the target. The target's own password field holding secure input doesn't block typing.
  - Without Accessibility, the value lands on the clipboard (concealed, transient) for a manual ⌘V.
- **Remember for ‹site›:** the preview of a password that isn't for the page shows **Fill and Remember for ‹site›**. No prompt after filling.
- **Paste icon:** in a password field it lists the page's passwords (all passwords outside browsers) and the page's authenticators, then Suggest Strong Password with the two options above. In a text field on a page with passwords for its site, an **Auth** chip offers them too (username, Tab, password).
  - Suggest Strong Password types the chosen password, then the next password field after it (confirm), saves it named after the site with the nearest text field above as username, and shows "Saved a password for ‹site›" · Undo. Undo deletes the saved password; what was typed stays in the page.
- **Me:** cards are listed at the end of Auth; + → New Card…; double-click or Edit… edits inline in the right pane. With cards, the paste icon gets a **Me** chip; it opens on Me when the field's kind is recognised and a card has that value. Fill Form fills only empty fields.

## Phase 3: system autofill (passwords and codes)
- An AutoFill **credential provider extension**, "Clipboard2", provides **passwords** and **one-time codes** (macOS 15+). Clipboard2 then appears in the system autofill suggestions in Safari, Chrome and apps, next to or instead of Apple Passwords.
- Register credential identities with `ASCredentialIdentityStore`:
  - every password (site + username)
  - authenticators and email codes as one-time code identities for their source's domain
  - Update them on every change and on sync.
- Filling from the system UI asks for Touch ID inside the extension, unless the app's unlock window is still open.
- Settings → Auth shows whether Clipboard2 is enabled as an autofill provider. If it isn't, it gives one line and **Open AutoFill Settings** (System Settings → General → AutoFill & Passwords). No dialogs.
- **Check first:** confirm that a Developer ID build can carry `com.apple.developer.authentication-services.autofill-credential-provider` (provisioning profile with the AutoFill capability). If it can't, stop and report back before building the rest of this phase.

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

### As built (1.11)
- Code: `Clipboard2/Services/Email/` (extractor, MIME, IMAP client and parser, OAuth, sources, `EmailCodeCenter`), `UI/Panel/EmailCodeViews.swift`, `UI/Settings/EmailAccountsSection.swift`. Tests: `Clipboard2Tests/EmailCodesTests.swift` (41-sample corpus).
- **Client ids** live in `Clipboard2/Resources/OAuthClients.plist` (`MicrosoftClientID`, `GoogleClientID`, `GoogleClientSecret`). It ships empty: an empty id hides that provider's Add button; IMAP is always offered.
- **Sign-in:** `ASWebAuthenticationSession` (ephemeral, so no "wants to sign in" alert) with a **loopback redirect** for both providers. The app listens on the loopback interface at a random port for that one request, then closes the sheet.
  - Microsoft: authority `common`, redirect `http://localhost:<port>`, scopes `openid email offline_access https://graph.microsoft.com/Mail.Read`. Public client, no secret.
  - Google: redirect `http://127.0.0.1:<port>`, scopes `openid email https://www.googleapis.com/auth/gmail.readonly`, `access_type=offline`, `prompt=consent`. Desktop client; its "secret" is sent as Google requires (it isn't secret).
  - The account's address comes from the id_token. Adding the same address again replaces its tokens (that's also how to reconnect after "Signed out").
- **Fetching** (decided):
  - Microsoft: `GET /me/mailFolders/inbox/messages?$filter=receivedDateTime ge <now−10 min>` with `Prefer: outlook.body-content-type="text"`, every 15 s. Not delta: the filter is stateless and returns only the window.
  - Gmail: `messages.list q="after:<epoch> {in:inbox category:updates}"` every 15 s, then each new id as `format=raw` (parsed by our MIME code). Not `history.list` (needs a stored history id; `newer_than:` only knows days).
  - IMAP: TLS on 993 (plain only if TLS is turned off under Advanced; no STARTTLS). LOGIN, EXAMINE INBOX (read-only), `UID SEARCH` (since yesterday the first time, then `UID n:*`), dates first via `UID FETCH (UID INTERNALDATE)`, then header fields + the first 32 KB of `BODY.PEEK[TEXT]` for the recent ones. IDLE (renewed every 9 min) when offered, else every 30 s.
  - Opening the panel and waking the Mac look at once. Errors back off ×2 per failure up to 15 min; a revoked sign-in waits 6 h (or until re-added). No accounts: no loops.
- **Kept:** code, sender's registrable domain, account id, time, in memory and one Keychain item (`<bundle id>.email`, account `codes`), dropped after 10 minutes. Accounts and credentials sit in the same small vault type (`EmailVault`) so phase 3 can move it to the shared Keychain.
- **Recognising:** URLs and addresses are removed first. Candidates: 4–8 digits, 3+3/4+4 digits split by a space or hyphen, or 6–8 capitals and digits with a digit (also `ABC-123`). Keywords additionally include confirm*, authenti*, Verifizierung*, Anmeldecode and any *code word; promo/QR/post/gift codes are negative keywords. Excluded: years 1900–2099, parts of dates/times/amounts/longer numbers, phone/IBAN groups, numbers after order/invoice/customer-number/tracking/phone words or `#`/`+`, numbers next to currencies or units, and anything near promotion words. Score = distance to the nearest keyword (a keyword after the code costs a little more, a code alone on its line a little less).
- **Shows:** Auth gets an "Email codes" section on top and the same code again as the first row of its source when that source is listed. Return pastes (transient, cleared after 30 s, never in history); the context menu also copies. Search matches the source.
- **Notifications:** "Code from ‹domain›", body "Open Auth to paste it" (or the code with Settings → Auth → Email accounts → "Show codes in notifications"); "Notify when a code arrives" turns them off. They follow the system permission and Focus, not the Sync notification switches. Clicking opens Auth with the code selected.
- **AutoFill hook:** `EmailCodeCenter.codesChanged()` has the one TODO to call `AutoFillIdentities.update(codes:)` once phase 3 lands.

### What the owner registers
- **Microsoft (Azure portal → Microsoft Entra ID → App registrations → New registration):**
  - Supported account types: "Accounts in any organizational directory and personal Microsoft accounts".
  - Platform: **Mobile and desktop applications**, redirect URI `http://localhost` (any port is accepted for localhost).
  - API permissions: Microsoft Graph, delegated: `Mail.Read`, `offline_access`, `openid`, `email` (no admin consent needed for personal accounts; some work tenants require it).
  - No client secret. Copy the Application (client) ID into `MicrosoftClientID`.
- **Google (Google Cloud console):**
  - Enable the **Gmail API**.
  - OAuth consent screen: External; app name, support email, developer contact; scopes `openid`, `.../auth/userinfo.email`, `https://www.googleapis.com/auth/gmail.readonly` (restricted).
  - Publishing status **In production** (Testing expires refresh tokens after 7 days). Don't submit for verification: unverified, up to 100 users, each sees Google's warning once.
  - Credentials → Create OAuth client ID → **Desktop app**. Nothing to register for the redirect (loopback `http://127.0.0.1:<port>` is allowed for desktop clients). Copy Client ID and Client secret into `GoogleClientID` / `GoogleClientSecret`.

## Not in scope
- Passkeys.
- Windows.
- Reading SMS codes. macOS already offers those from Messages.
- Sharing passwords with contacts. Group sharing works as for secrets.
