-- Authenticators (docs/sync/PROTOCOL.md, "Authenticators"): an `authenticator` space whose only member
-- is its owner holds one TOTP account as a single `otp` item. The seed never leaves the owner: people
-- it's shared with get batches of pre-computed codes, sealed to them, one batch per share.

ALTER TABLE spaces DROP CONSTRAINT spaces_kind_check;
ALTER TABLE spaces ADD CONSTRAINT spaces_kind_check CHECK (kind IN ('personal', 'group', 'direct', 'authenticator'));

ALTER TABLE items DROP CONSTRAINT items_category_check;
ALTER TABLE items ADD CONSTRAINT items_category_check
  CHECK (category IN ('history', 'pinned', 'snippet', 'secret', 'folder', 'otp'));

-- A share and its current code batch. codes_until/sealed_codes are NULL until the owner's devices
-- upload the first batch (a share made by a transfer starts empty).
CREATE TABLE authenticator_shares (
  space_id      uuid NOT NULL REFERENCES spaces (id) ON DELETE CASCADE,
  recipient_uid text NOT NULL REFERENCES users (uid) ON DELETE CASCADE,
  codes_until   bigint,
  sealed_codes  bytea,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (space_id, recipient_uid)
);
CREATE INDEX authenticator_shares_recipient ON authenticator_shares (recipient_uid);
