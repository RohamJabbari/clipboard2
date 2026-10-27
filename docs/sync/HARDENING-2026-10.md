# Sync hardening and new features (October 2026)

The contract the server, Mac and Windows changes are built against. Server and both clients
must follow it exactly; PROTOCOL.md gets updated to match.

## Server (server/)

- **Client IPs:** `trustProxy: 1` (Cloud Run's front end is one hop), so rate limits see the real IP.
- **Auth rate limits** (prelogin, signup, login) are counted in Postgres (a small table with fixed
  windows), so they hold across instances. scrypt verification runs at most 2 at a time per
  instance; beyond a short queue answer `429 rate_limited` with `retryAfter`.
- **Invite-only sign-up.** `POST /v1/auth/signup` needs either:
  - `signupCode`: a sign-up code (below), consumed in the sign-up transaction; or
  - `groupInviteId`: the hex `inviteId` of an unused, unexpired group invite (not consumed here;
    joining consumes it).

  Missing either → `403 invite_required`. Unknown/used/expired → `403 invite_invalid`.
- **Sign-up codes:**
  - `POST /v1/signup-codes` → `201 {"id","code","expiresAt"}`. The server makes 80 random bits and shows
    them in the invite-code alphabet as 4 groups of 4 (`XXXX-XXXX-XXXX-XXXX`). It stores only SHA-256
    of the normalised code. Codes expire after 14 days. At most 10 unused per user, otherwise
    `429 too_many_codes`.
  - `GET /v1/signup-codes` lists the open codes as `{"id","createdAt","expiresAt"}`.
  - `DELETE /v1/signup-codes/:id` → `204`.
- **Devices:** sessions get a public `id` (uuid).
  - `GET /v1/sessions` → `{"sessions":[{"id","deviceName","createdAt","lastUsedAt","current"}]}`.
  - `DELETE /v1/sessions/:id` → `204`. It may be the current session.
- **Item writes:**
  - `sortAt`/`updatedAt` more than 10 minutes in the future → `400 clock_skew`.
  - In a group, overwriting or deleting an existing item is allowed only for its author or the group
    owner. Anyone else gets `403 forbidden`. Creating new items is unchanged.
  - `blobIds` may hold up to 12 ids.
- **Quotas:**
  - Per author: 1 GB, unchanged.
  - Per group: 2 GB and 5,000 live items, giving `413 quota_exceeded` with `"scope":"group"`.
  - Global: `LIMIT_TOTAL_BYTES`, default 20 GB, giving `"scope":"server"`.
- **Account deletion** also tombstones (`deleted:"user"`) every item the user authored in other spaces
  and drops their blobs, so nothing is left counting against nobody.
- **Change feed:** every item write first locks the space row (`SELECT … FOR UPDATE`), so `seq`
  order equals commit order. `/changes` reads `purged_seq` and the items in one REPEATABLE READ
  transaction.
- **Blob upload URLs:** when the register request has `"ifGenerationMatch": true`, the signed PUT
  requires the header `x-goog-if-generation-match: 0` (clients must send it). No upload URL is
  issued for a blob id an item already references.
- **Privacy:**
  - `GET /v1/groups/:id/members` returns `{"uid","username","name","role"}`, with no email.
  - Request logs don't record IPs or emails.

## Payloads (both clients)

- **`rev`:** every payload (clip, snippet, secret) includes `"rev"`, the `updatedAt` (ms) the
  writer sends with it. A reader drops an item whose `rev` is present and ≠ the server's
  `updatedAt`, and never applies an item whose `rev` is lower than the `updatedAt` it already has for
  that id (rollback protection). Payloads without `rev` (older apps) are accepted.
- **`toDevice`:** a clip payload may carry this, a session `id` from `/v1/sessions`. The named
  device shows a "Sent from ‹device›" notice and puts the item at the top. Everyone else treats it
  as a normal item. The sender also writes `"fromDevice"` (its own device name) for that notice.
- **Received times:** `createdAt`/`lastCopiedAt` from the payload are clamped to the time the
  item arrived.

## Clients (Mac and Windows)

- **KDF bounds:** iterations outside 600,000–10,000,000 are refused before deriving. Keep the last
  KDF parameters per email locally, and refuse a later prelogin that lowers them.
- **Key pinning:** on first unwrap of a space key, store its SHA-256 per space id with the session
  keys. If a later wrap unwraps to a different key, don't adopt it, stop syncing that space, and
  show "This group's key changed unexpectedly" (leave and rejoin clears the pin).
- **Received files:** mark them as downloaded. On Mac, quarantine attributes naming
  Clipboard2. On Windows, a `Zone.Identifier` stream with `ZoneId=3`.
- **Errors:**
  - 400 `clock_skew` → item-permanent, plus a visible "Your clock is off" sync error.
  - 403 `forbidden` → item-permanent, with the local edit kept locally.
  - 413 `quota_exceeded` → item-permanent until the next launch or a deletion.
  - 429 → back off for `retryAfter`.
  - Deletions are pushed **before** uploads.
- **Polling cadence:** every 3 s while the quick panel is open. Every 15 s while the user was
  active in the last 5 minutes (a copy, paste, panel or menu). Otherwise every 60 s. Always sync
  once on panel open and after local changes (3 s debounce, unchanged).
- **Sign-up:** a required "Invite code" field takes a sign-up code or a group invite code. With a
  group code, the app joins that group right after the account is created. Settings → Sync gains
  "Invite Someone": create a code, copy it, see and revoke open codes.
