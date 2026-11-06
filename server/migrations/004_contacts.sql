-- Contacts (docs/sync/PROTOCOL.md, "Contacts"): `direct` spaces with exactly two members, made by a
-- username request (accepted or declined) or by a one-time code (an ordinary row in invites).

ALTER TABLE spaces DROP CONSTRAINT spaces_kind_check;
ALTER TABLE spaces ADD CONSTRAINT spaces_kind_check CHECK (kind IN ('personal', 'group', 'direct'));

-- The two people of a direct space as an ordered pair, so two people have at most one direct space
-- however they got there and whoever asked first: the unique index settles concurrent requests in
-- both directions. Written with the request (pending) or when a code is accepted; a code's space has
-- no row until then, since nobody knows yet who will enter it.
CREATE TABLE direct_pairs (
  space_id uuid PRIMARY KEY REFERENCES spaces (id) ON DELETE CASCADE,
  uid_low  text NOT NULL REFERENCES users (uid) ON DELETE CASCADE,
  uid_high text NOT NULL REFERENCES users (uid) ON DELETE CASCADE,
  CHECK (uid_low < uid_high)
);
CREATE UNIQUE INDEX direct_pairs_pair ON direct_pairs (uid_low, uid_high);
CREATE INDEX direct_pairs_high ON direct_pairs (uid_high);

-- Pending username requests. The recipient isn't a member until they accept; until then their
-- wrapped copy of SK waits here.
CREATE TABLE contact_requests (
  space_id              uuid PRIMARY KEY REFERENCES spaces (id) ON DELETE CASCADE,
  requester             text NOT NULL REFERENCES users (uid) ON DELETE CASCADE,
  recipient             text NOT NULL REFERENCES users (uid) ON DELETE CASCADE,
  recipient_wrapped_key bytea NOT NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  CHECK (requester <> recipient)
);
CREATE INDEX contact_requests_requester ON contact_requests (requester, created_at);
CREATE INDEX contact_requests_recipient ON contact_requests (recipient, created_at);

-- Open codes per creator, and housekeeping of abandoned direct spaces.
CREATE INDEX invites_created_by ON invites (created_by, expires_at);
CREATE INDEX spaces_direct ON spaces (created_at) WHERE kind = 'direct';
