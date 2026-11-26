# Passwordless accounts (1.13)

Server + Mac. Windows keeps using password accounts unchanged; nothing here breaks it (see
[Existing password accounts](#existing-password-accounts)). Wire details live in
[`docs/sync/PROTOCOL.md`](../sync/PROTOCOL.md) → *Passwordless*; this file is the design and the
reasoning behind it.

## Goals

- No password to forget or phish. The account key (`AK`) never leaves trusted devices in the clear and
  the server still never sees a vault key.
- A new device gets `AK` only when an already-trusted device approves it, with the human checking a
  number shown on the new device (number matching).
- Every device has a **session window** chosen on that device; the server enforces it and the client
  wipes itself when it ends.
- Losing every device is survivable when the user set up **recovery** (contacts, or later an emailed
  code), and never silently: recovery always has a waiting period during which the account's devices
  can stop it.
- Emails are stored encrypted, looked up through a blind index, and can be verified (Google now,
  emailed codes later).

## Decisions

| Topic | Decision |
|---|---|
| Sign up | Email + username, invite-only as today. The first device generates `AK`, `idPriv`, the personal space, and a **device key**; its session is trusted indefinitely. |
| Email verification | **Continue with Google** (ID token checked server-side: RS256 signature against Google's JWKS, `iss`, `aud` = the Mac OAuth client id, `exp`, `iat` ≤ 10 min old, `email_verified`, single use). Emailed codes are built but behind `FEATURE_EMAIL_CODES` (off: no mail sending yet). |
| Unverified vs verified | An unverified address can be claimed later by a verified one; the verified claim wins and the unverified account is told to change its email. Password login still finds it by its old address (so Windows users are never locked out by someone else's claim). |
| Email storage | `email_index = HMAC-SHA256(indexKey, email)` (unique, lookups) and `email_enc = AES-256-GCM(encKey, email)` (for sending mail later). Both keys are HKDF'd from `SERVER_SECRET` (Secret Manager → env). Existing rows are migrated at startup. |
| Gmail | The same Google consent optionally asks for `gmail.readonly` (incremental auth, `include_granted_scopes=true`; Google shows a checkbox per scope). Granted → the Gmail account is added to email codes. Declined → nothing else happens. |
| New device | Identifier (email or username) → new device makes a P-256 key pair and a request → all signed-in devices of the account see it on their next heads poll → the approver picks the matching number out of 3 (button disabled for 3 s) → the approver wraps `AK` to the new device's public key. |
| Number | `10 + (u32be(SHA-256("c2/number/v1" ‖ requestId ‖ devicePub)[0..4]) mod 90)`. Derived from the device's public key, so a server that swaps the key changes the number the approver must pick (see threat model). Decoys are made by the approver's client. |
| "This wasn't me" | Denies, blocks that IP and that device key for the account for 30 days, and pauses new requests for the account for 1 hour. |
| Limits | Requests expire after 5 minutes. Per 10 minutes: 5 requests per account, 10 per IP, 3 per device key. Polls 40/min per request. |
| New country | The approver sees "New location" when the request's country was never seen on that account's sessions. Location comes from load-balancer headers when `GEO_HEADERS=1` (never trusted otherwise); without it the approver sees "Location unknown". |
| Session window | 1 hour, 1 day, 1 week, custom (15 min – 365 days), or indefinitely, chosen on the new device. The server sets a hard `expires_at` (no sliding) and deletes the session after it; the client wipes keys, sync state and synced data at the same moment. Indefinitely needs the typed phrase **I understand the risks and I wish to proceed** (checked by client and server). |
| Changing a window | Any device can shorten any device's window. Only the device itself can lengthen its own (indefinitely again needs the phrase). |
| Recovery | Optional, chosen in onboarding or Settings: **1 contact** (`AK = s₁ ⊕ s_server`), **2 contacts** (`AK = s₁ ⊕ s₂ ⊕ s_server`), or **recovery code by email** (behind the same off flag). Waiting period **72 h** from the start of a recovery, during which every device of the account sees it and can cancel. |
| No recovery, one device | Settings shows a persistent inline warning. |
| Password accounts | Keep working. A Mac signed in with a password can **Switch to passwordless**: the session becomes a device session (indefinite). The password is kept as a fallback by default (Windows needs it); it is retired only when the user confirms *and* no other password session is signed in. |
| UI | Inline only: no sheets, alerts or confirmation dialogs in any new flow. |

## Cryptography

All primitives are the existing ones (PROTOCOL.md → Primitives): AES-256-GCM `AEAD`, HKDF-SHA256,
P-256 ECDH (X9.63 keys). CryptoKit on the Mac, Node `crypto` on the server.

```
wrapTo(pub, secret, info, aad):                    the same shape as wrapSpaceKey
    eph  = fresh P-256 key
    k    = HKDF(ECDH(eph.priv, pub), eph.pub ‖ pub, info)
    out  = eph.pub(65) ‖ AEAD(k, secret, aad)

device key       devPriv/devPub = fresh P-256 key, made by each passwordless device, kept in its Keychain
AK to a device   wrapTo(devPub, AK, "c2/device/v1/" + requestId, "c2/device/v1/" + uid + "/" + requestId)
number           10 + (u32be(SHA-256(utf8("c2/number/v1") ‖ utf8(requestId) ‖ devPub)[0..4]) mod 90)

recovery split   n shares: s₁…s_{n-1} = random(32), s_n = AK ⊕ s₁ ⊕ … ⊕ s_{n-1}   (XOR n-of-n)
contact share    wrapTo(contactIdPub, sᵢ, "c2/recshare/v1/" + setupId, "c2/recshare/v1/" + setupId + "/" + contactUid)
to new device    wrapTo(devPub, sᵢ, "c2/recdev/v1/" + recoveryId, "c2/recdev/v1/" + recoveryId + "/" + (contactUid | "server" | "email"))
escrow at rest   AEAD(escrowKey, s_server, "c2/escrow/v1/" + setupId)
email method     code = random(16) (shown as an invite-style code), wrapped = AEAD(HKDF(code, "", "c2/reccode/v1"), s_email, "c2/reccode/v1/" + setupId)

server keys      indexKey  = HKDF(SERVER_SECRET, "", "c2/server/email-index")
                 encKey    = HKDF(SERVER_SECRET, "", "c2/server/email-enc")
                 escrowKey = HKDF(SERVER_SECRET, "", "c2/server/escrow")
email_index      HMAC-SHA256(indexKey, normalized email)
email_enc        AEAD(encKey, utf8(email), "c2/email/v1")
```

A recovered device checks `AK` by opening `wrappedPrivateKey` with it (GCM authenticates), so a
wrong share fails loudly instead of producing garbage.

**Shares and who can recover:**

| Method | Holders | Who alone can recover | Who together |
|---|---|---|---|
| 1 contact | contact (s₁), server (s₂) | nobody | contact + server, after the wait |
| 2 contacts | A (s₁), B (s₂), server (s₃) | nobody, not even A + B | A + B + server, after the wait |
| Email code | server (wrapped s₁ and s₂), the user's mailbox (code) | nobody | mailbox + server, after the wait |

Setting recovery up again makes new random shares and deletes the server's old escrow share, so old
contact shares stop combining to `AK`.

## Flows

### Sign up (passwordless)
1. Invite code (as today), email **or** Continue with Google, username (required).
2. The Mac generates `uid`, `AK`, `idPriv`, personal space key, and the device key. `wrappedPrivateKey`
   and the personal space key are wrapped as today; **no `wrappedAccountKey` and no KDF**.
3. `POST /v1/auth/passwordless/signup`. The session is a device session with window indefinitely.
4. Onboarding continues with the Recovery section shown inline.

### Continue with Google
`OAuthSignIn` runs the existing PKCE loopback flow with `openid email` plus, optionally,
`gmail.readonly`, `include_granted_scopes=true`, `access_type=offline`, `prompt=consent`. The token
response's `scope` says what was granted. The `id_token` goes to the server (signup, or
`PUT /v1/account/email` to verify an existing account). If Gmail was granted, the access/refresh
tokens become an email-codes account exactly as if added in Settings → Email Codes.

### Sign in on a new device
1. Enter email or username, choose the session window (Indefinitely shows the risk text inline and
   the phrase field).
2. `POST /v1/auth/device-requests` → `{requestId, secret, expiresAt}`. Unknown identifiers get an
   identical answer whose request never gets approved, so this can't find accounts.
3. The new device shows its number big, the window, and a countdown; it polls
   `POST /v1/auth/device-requests/:id/poll` every 2 s.
4. Signed-in devices see `security` move in `GET /v1/heads`, fetch `GET /v1/device-requests`, and
   show an inline card (Settings → Sync, top) plus a system notification. The card shows device
   name, platform, approximate location, time, requested window, "New location" when it applies,
   three number buttons (disabled for 3 s), and **This wasn't me**.
5. Picking a number: the approver's client checks it against the number it derives from `devPub`;
   a wrong pick reports a mismatch (the request is dead; the new device says so). A right pick
   wraps `AK` and `POST /v1/device-requests/:id/approve {number, wrappedAccountKey}` (the server
   checks the number again).
6. The new device's next poll creates its session (`kind: device`, window as chosen), returns the
   token, `Account` and the wrapped `AK`. It opens `AK`, then `idPriv`, then syncs.

### Session windows
- Server: `sessions.expires_at` is hard for device sessions (no sliding); indefinitely is stored as
  100 years. Expired sessions answer `401` and are deleted by a sweep.
- Mac: `StoredSyncSession.expiresAt`. A timer (and every launch, wake and poll) checks it; at expiry
  the Mac signs out *and* removes everything synced (personal history included, since it came from
  the account) and the keys. `401` on a device session does the same (revoked elsewhere).
- Settings → Devices shows each device's window and expiry; **Change** shortens (any device) or
  lengthens (this device only).

### Recovery
**Set up** (Settings → Recovery, or onboarding): pick 1 or 2 of your contacts. The Mac splits `AK`,
wraps each share to the contact's public key and uploads them with the server share
(`PUT /v1/account/recovery`). Each contact sees an invitation (heads → `security`) and accepts or
declines inline; the setup is **active** once all have accepted. A contact can step down later; the
setup becomes **broken** and the owner sees it.

**Recover** (on a new device, when no trusted device is left): enter email or username, pick
"Recover with contacts", choose the window. `POST /v1/auth/recovery` starts it; the release time is
`now + 72 h`. Each contact sees the request with the number matching card, unwraps their share and
re-wraps it to the new device. Every device of the account sees a red inline banner "Someone is
recovering your account" with **Cancel recovery**; cancelling pauses new requests for 24 h. Once all
contacts approved **and** the release time passed, the new device's poll gets the contact shares and
the server's share (wrapped by the server to `devPub`), a session, and the account.

**Recovery code by email** (behind `FEATURE_EMAIL_CODES`): the Mac makes the code, splits `AK` into
an escrow share and a code-wrapped share, and sends the code once to the server, which emails it and
forgets it. Before enabling, the user must accept inline that anyone who gets that email (a leaked
mailbox, a forwarding rule, the mail provider) plus a working server can recover the account after
the waiting period, and that we will never ask for that code. Off until mail sending exists.

**Warning:** with no active recovery and exactly one device, Settings shows a persistent inline
warning ("If you lose this Mac, your synced data is gone.").

### Existing password accounts
- Login, prelogin, password change and Windows are untouched. Mac password logins now also send
  `platform: "macos"`.
- **Switch to passwordless** (Mac, signed in with a password): `POST /v1/account/passwordless
  {authKey, devicePublicKey, retirePassword}`. The current session becomes a device session,
  indefinitely. `retirePassword: true` deletes the password verifier, KDF and `wrappedAccountKey`, and
  is refused (`409 password_devices`) while another password session is signed in. Decision: keep the
  password as a fallback by default until Windows supports device approval; the toggle says Windows
  needs it.
- Accounts whose password was retired can't log in with a password (`invalid_credentials` after the
  same scrypt work, like an unknown email).

### Deleting a passwordless account
`DELETE /v1/account {"confirm": "<username>"}` from a device session. Settings asks for the username
inline. (A stolen unlocked device can do this; see the threat model.)

## Threat model

**Assets:** `AK` (and through it `idPriv` and every space key), session tokens, email addresses,
recovery shares.

**Trust:** the user's devices while unlocked; the server for availability, rate limiting, waiting
periods and metadata, *not* for confidentiality of vault data; Google for the claim "this person
controls this Gmail address".

| Threat | Defence | Residual risk |
|---|---|---|
| Phishing / remote attacker requests a login | Requests reach only the user's own devices; number matching means a user who taps "approve" blindly can't succeed by chance more than 1 in 3, and a wrong pick kills the request. Approve is disabled for 3 s (no reflex taps). "This wasn't me" blocks the source and pauses the account. | A user who reads the attacker's number over the phone and picks it. The card says "Only approve if you are signing in yourself right now." |
| Request flooding (MFA fatigue) | 5 requests / 10 min per account, 10 per IP, 3 per device key; pause after a denial. | A distributed attacker can still send 5 per 10 minutes. |
| Malicious or compromised server substitutes the device key | The number is derived from `devPub` on both sides; a swapped key gives the approver a different correct number, the real one shows on the new device, and the approver's client refuses a mismatch. | A server that also shows the user a fake new-device screen (impossible: that screen is the user's own app). |
| Server database leak | Emails are HMAC'd and encrypted with keys not in the database; escrow shares are encrypted the same way; tokens and secrets are stored hashed; vault data is ciphertext. | `SERVER_SECRET` leaking together with the database reveals emails and escrow shares; escrow alone is useless without the contacts' shares. |
| Malicious server tries recovery | Needs every contact's share (contacts must approve with number matching). | Server colluding with all recovery contacts. Email method: the server sees the code once when mailing it (stated in the inline risk text). |
| Rogue recovery contact(s) | A contact's share alone is useless; with 2 contacts both are needed; the server share is released only after 72 h during which every device is told and can cancel. | A user who lost every device *and* ignores everything for 72 h. |
| Lost or stolen device | Session windows; revoke from any other device (`401` → the device wipes itself); indefinitely needs the typed acknowledgement. | Data already decrypted on a stolen unlocked device can't be recalled; an indefinite session keeps working until revoked; anyone at the unlocked Mac can approve new devices or delete the account. |
| Stale device after expiry | Hard server expiry plus client-side wipe at the same instant. | A device offline at expiry wipes when it next runs or polls; until then its local copy stays (as with any offline device). |
| Account enumeration | Device requests, recovery starts and prelogin answer the same for unknown identifiers. | Timing differences of a few ms. Signup still reveals a taken username (as before). |
| Google ID token replay | `aud` must be our client id, `iat` ≤ 10 min, each token accepted once. | A token stolen within its first 10 minutes can verify that address once. |
| Unverified email squatting | A verified claim takes the address over; the squatter is told to change it. Password login still works for the squatter by its old address. | None of note: emails are not used to unlock anything. |
| Spoofed location headers | Only trusted when `GEO_HEADERS=1` (set only behind a load balancer that overwrites them). | Location is approximate and only advisory. |

## Out of scope (now)
- Windows support for device approval, passwordless sign-up and recovery.
- Mail sending (codes and the email recovery method stay behind `FEATURE_EMAIL_CODES`).
- Push notifications; approvals arrive with the heads poll (2–10 s).
- Rotating `AK` after recovery or after revoking a device (revocation is enforced by the server, as for
  group members today).
