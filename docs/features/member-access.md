# Group member access (1.10)

A group has one **Owner** and any number of **Members**. Each member has two permissions, both on by default:

- **Send**: can add things to the group: share or copy items, create folders, ⌥⌘C / Ctrl+Alt+C, save secrets into it.
- **Secrets**: can see the group's secrets. Without it, the group's secrets don't exist for them: they aren't downloaded, listed, counted, searched or notified about.

The owner always has both, and only the owner changes them. Contacts (direct spaces) and authenticators are unchanged.

## Server
- Migration `007_member_access.sql`: `space_members` gains `can_send boolean NOT NULL DEFAULT true` and `can_see_secrets boolean NOT NULL DEFAULT true`. Existing members keep both.
- `PATCH /v1/groups/:id/members/:uid {canSend?: boolean, canSeeSecrets?: boolean}`.
  - Owner only (403 `forbidden` otherwise). The owner's own row can't be changed (400).
  - Returns the member as `GET /v1/groups/:id/members` lists it.
- `GET /v1/groups/:id/members` and the group entries of `GET /v1/spaces` carry `canSend` and `canSeeSecrets`: per member, plus the caller's own on the space.
- Enforcement:
  - `GET /v1/spaces/:id/changes`: for a caller without `can_see_secrets`, rows with `category = 'secret'` are left out entirely (not even tombstones).
  - `PUT /v1/spaces/:id/items/:itemId`:
    - A caller without `can_send` gets 403 `send_not_allowed` for a new item or a change.
    - A caller without `can_see_secrets` gets 403 `forbidden` for any secret item.
  - `POST /v1/spaces/:id/blobs`: without `can_send`, 403 `send_not_allowed`.
  - `DELETE /v1/spaces/:id/items/:itemId`:
    - Members without Send may still delete their own earlier items (the existing author/owner rule applies).
    - Secrets need `can_see_secrets`.
- Document all of it in `docs/sync/PROTOCOL.md`.

## Clients (Mac and Windows build the same thing)
- **Manage group sheet**: each member row (not the owner's) shows the role and two small toggle pills, **Send** and **Secrets**.
  - Tapping one changes it at once, with no confirm.
  - On failure the pill reverts with a notice.
  - Non-owners see the pills read-only for themselves only ("You can't send to this group").
- **Your own access** comes from the spaces list.
  - **Without Send**, everything that would write to the group is hidden or disabled:
    - Share to Group targets, ⌥⌘C / Ctrl+Alt+C for that group, Add Items, New Folder, moving into the group, Save as Secret into it, and drag and drop.
    - The group still works for reading and pasting.
    - ⌥⌘C to a default group you can't send to shows "You can't send to ‹Group›".
  - **Without Secrets**:
    - Drop the group's secrets from this device (Keychain / protected store) and never show them in the group's Saved, search or counts.
    - Hide "Share to Group" for secrets to that group.
  - **Secrets turned back on** (false → true): reset that space's pull cursor, so the next sync downloads its secrets again.
- **Notifications**: tell the member when their access changes. Title "‹Group›", body "You can send again" / "You can no longer send" / "You can see secrets again" / "You can no longer see secrets". Under the Group members kind.
- Older clients keep working. The server enforces the rules, and their refused writes surface as the usual sync warning.

## Not in scope
Per-folder permissions, more roles (admins), and secret key rotation. Revoking Secrets access stops new and existing secrets from being delivered, but anything a device already decrypted could have been kept by a modified client. Change sensitive secrets after removing someone.
