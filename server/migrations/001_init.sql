-- Clipboard2 sync v1 (docs/sync/PROTOCOL.md). Everything user-written is ciphertext; the password
-- never arrives here, only authKey, which is stored as scrypt(authKey).

CREATE TABLE settings (
  name  text PRIMARY KEY,
  value bytea NOT NULL
);

CREATE TABLE users (
  uid                 text PRIMARY KEY,
  email               text NOT NULL,
  auth_salt           bytea NOT NULL,
  auth_hash           bytea NOT NULL,
  kdf_salt            bytea NOT NULL,
  kdf_iterations      integer NOT NULL,
  wrapped_account_key bytea NOT NULL,
  public_key          bytea NOT NULL,
  wrapped_private_key bytea NOT NULL,
  personal_space_id   uuid NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX users_email ON users (lower(email));

CREATE TABLE sessions (
  token_hash   bytea PRIMARY KEY,
  uid          text NOT NULL REFERENCES users (uid) ON DELETE CASCADE,
  device_name  text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL
);
CREATE INDEX sessions_uid ON sessions (uid);

CREATE TABLE spaces (
  id             uuid PRIMARY KEY,
  kind           text NOT NULL CHECK (kind IN ('personal', 'group')),
  owner_uid      text NOT NULL REFERENCES users (uid) ON DELETE CASCADE,
  encrypted_name bytea,
  -- Tombstones at or below this seq have been purged; older cursors must reset.
  purged_seq     bigint NOT NULL DEFAULT 0,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX spaces_owner ON spaces (owner_uid);

CREATE TABLE space_members (
  space_id    uuid NOT NULL REFERENCES spaces (id) ON DELETE CASCADE,
  uid         text NOT NULL REFERENCES users (uid) ON DELETE CASCADE,
  role        text NOT NULL CHECK (role IN ('owner', 'member')),
  wrapped_key bytea NOT NULL,
  added_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (space_id, uid)
);
CREATE INDEX space_members_uid ON space_members (uid);

CREATE SEQUENCE item_seq;

CREATE TABLE items (
  space_id   uuid NOT NULL REFERENCES spaces (id) ON DELETE CASCADE,
  id         uuid NOT NULL,
  seq        bigint NOT NULL DEFAULT nextval('item_seq'),
  category   text NOT NULL CHECK (category IN ('history', 'pinned', 'snippet', 'secret')),
  sort_at    bigint NOT NULL,
  updated_at bigint NOT NULL,
  deleted    text CHECK (deleted IN ('user', 'trimmed')),
  deleted_at timestamptz,
  ciphertext bytea,
  blob_ids   uuid[] NOT NULL DEFAULT '{}',
  size       integer NOT NULL DEFAULT 0,
  author_uid text REFERENCES users (uid) ON DELETE SET NULL,
  PRIMARY KEY (space_id, id)
);
CREATE INDEX items_changes ON items (space_id, seq);
CREATE INDEX items_live ON items (space_id, category, sort_at DESC, id DESC) WHERE deleted IS NULL;
CREATE INDEX items_tombstones ON items (space_id, deleted_at) WHERE deleted IS NOT NULL;
CREATE INDEX items_author ON items (author_uid) WHERE deleted IS NULL;

CREATE TABLE blobs (
  space_id   uuid NOT NULL REFERENCES spaces (id) ON DELETE CASCADE,
  id         uuid NOT NULL,
  size       bigint NOT NULL,
  owner_uid  text REFERENCES users (uid) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (space_id, id)
);
CREATE INDEX blobs_owner ON blobs (owner_uid, created_at);

CREATE TABLE invites (
  id         text PRIMARY KEY,
  space_id   uuid NOT NULL REFERENCES spaces (id) ON DELETE CASCADE,
  sealed_key bytea NOT NULL,
  created_by text REFERENCES users (uid) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL
);
CREATE INDEX invites_space ON invites (space_id);
