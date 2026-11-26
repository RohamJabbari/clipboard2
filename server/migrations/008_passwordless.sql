-- Passwordless accounts (docs/features/passwordless.md): encrypted emails, device sessions with
-- windows, device approval requests, recovery, email verification.

-- Users: the password parts become optional (passwordless accounts have none), and the email moves
-- to a blind index plus ciphertext. The plaintext column stays nullable until every row is migrated
-- (done at startup by migrateEmails, which needs SERVER_SECRET and so can't run here).
ALTER TABLE users ALTER COLUMN email DROP NOT NULL;
ALTER TABLE users ALTER COLUMN auth_salt DROP NOT NULL;
ALTER TABLE users ALTER COLUMN auth_hash DROP NOT NULL;
ALTER TABLE users ALTER COLUMN kdf_salt DROP NOT NULL;
ALTER TABLE users ALTER COLUMN kdf_iterations DROP NOT NULL;
ALTER TABLE users ALTER COLUMN wrapped_account_key DROP NOT NULL;
ALTER TABLE users
  ADD COLUMN email_index bytea,
  ADD COLUMN email_enc bytea,
  ADD COLUMN email_verified boolean NOT NULL DEFAULT false,
  -- Set when a verified claim took this account's (unverified) address: password login still finds it.
  ADD COLUMN email_released_index bytea,
  -- The email's local part, only for accounts without a username (shown to group members as before).
  ADD COLUMN fallback_name text,
  -- After "This wasn't me", new device requests wait until then.
  ADD COLUMN requests_paused_until timestamptz,
  -- After a cancelled recovery, new recoveries wait until then.
  ADD COLUMN recovery_paused_until timestamptz;
CREATE UNIQUE INDEX users_email_index ON users (email_index);
CREATE INDEX users_email_released ON users (email_released_index) WHERE email_released_index IS NOT NULL;
UPDATE users SET fallback_name = split_part(email, '@', 1) WHERE username IS NULL AND email IS NOT NULL;

-- Sessions: device sessions carry the device's public key and a hard expiry (window_ms NULL with
-- kind 'device' means indefinitely).
ALTER TABLE sessions
  ADD COLUMN kind text NOT NULL DEFAULT 'password' CHECK (kind IN ('password', 'device')),
  ADD COLUMN device_public_key bytea,
  ADD COLUMN platform text,
  ADD COLUMN window_ms bigint,
  ADD COLUMN country text,
  ADD COLUMN city text;
CREATE INDEX sessions_expires ON sessions (expires_at);

-- A new device asking to be let in. uid is NULL for an unknown identifier (an answer that looks real).
CREATE TABLE device_requests (
  id                  uuid PRIMARY KEY,
  uid                 text REFERENCES users (uid) ON DELETE CASCADE,
  secret_hash         bytea NOT NULL,
  device_public_key   bytea NOT NULL,
  device_name         text,
  platform            text,
  country             text,
  city                text,
  new_country         boolean NOT NULL DEFAULT false,
  ip_key              bytea NOT NULL,
  window_ms           bigint,
  status              text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'approved', 'completed', 'denied', 'mismatch', 'cancelled')),
  wrapped_account_key bytea,
  decided_by          uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  expires_at          timestamptz NOT NULL
);
CREATE INDEX device_requests_uid ON device_requests (uid, expires_at);

-- "This wasn't me": an IP or device key (both HMAC'd) refused for one account until `until`.
CREATE TABLE device_blocks (
  uid   text NOT NULL REFERENCES users (uid) ON DELETE CASCADE,
  key   bytea NOT NULL,
  until timestamptz NOT NULL,
  PRIMARY KEY (uid, key)
);

-- Fixed windows of any length (device requests, recoveries, email codes). key is an HMAC.
CREATE TABLE rate_buckets (
  key          bytea NOT NULL,
  window_start timestamptz NOT NULL,
  hits         integer NOT NULL,
  expires_at   timestamptz NOT NULL,
  PRIMARY KEY (key, window_start)
);
CREATE INDEX rate_buckets_expires ON rate_buckets (expires_at);

-- Google ID tokens already used (single use), until they'd be too old anyway.
CREATE TABLE used_id_tokens (
  hash       bytea PRIMARY KEY,
  expires_at timestamptz NOT NULL
);

-- Email verification codes (behind FEATURE_EMAIL_CODES).
CREATE TABLE email_codes (
  uid        text PRIMARY KEY REFERENCES users (uid) ON DELETE CASCADE,
  code_hash  bytea NOT NULL,
  attempts   integer NOT NULL DEFAULT 0,
  expires_at timestamptz NOT NULL
);

-- Recovery: one setup per account. escrow_share is the server's share, encrypted with escrowKey.
CREATE TABLE recovery_setups (
  id             uuid PRIMARY KEY,
  uid            text NOT NULL UNIQUE REFERENCES users (uid) ON DELETE CASCADE,
  method         text NOT NULL CHECK (method IN ('contacts', 'email')),
  escrow_share   bytea NOT NULL,
  wrapped_secret bytea,
  -- How many contacts hold a share; fewer rows (a contact stepped down or deleted their account) means broken.
  contacts_needed integer NOT NULL DEFAULT 0,
  broken         boolean NOT NULL DEFAULT false,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE recovery_contacts (
  setup_id      uuid NOT NULL REFERENCES recovery_setups (id) ON DELETE CASCADE,
  contact_uid   text NOT NULL REFERENCES users (uid) ON DELETE CASCADE,
  wrapped_share bytea NOT NULL,
  accepted_at   timestamptz,
  PRIMARY KEY (setup_id, contact_uid)
);
CREATE INDEX recovery_contacts_contact ON recovery_contacts (contact_uid);

-- A recovery in progress. uid/setup_id are NULL for an unknown identifier or a method the account
-- hasn't set up (an answer that looks real).
CREATE TABLE recovery_requests (
  id                uuid PRIMARY KEY,
  uid               text REFERENCES users (uid) ON DELETE CASCADE,
  setup_id          uuid REFERENCES recovery_setups (id) ON DELETE CASCADE,
  method            text NOT NULL,
  secret_hash       bytea NOT NULL,
  device_public_key bytea NOT NULL,
  device_name       text,
  platform          text,
  country           text,
  city              text,
  ip_key            bytea NOT NULL,
  window_ms         bigint,
  status            text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'completed', 'denied', 'mismatch', 'cancelled')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  release_at        timestamptz NOT NULL,
  expires_at        timestamptz NOT NULL
);
CREATE INDEX recovery_requests_uid ON recovery_requests (uid, expires_at);
CREATE INDEX recovery_requests_setup ON recovery_requests (setup_id);

CREATE TABLE recovery_approvals (
  request_id    uuid NOT NULL REFERENCES recovery_requests (id) ON DELETE CASCADE,
  contact_uid   text NOT NULL REFERENCES users (uid) ON DELETE CASCADE,
  wrapped_share bytea NOT NULL,
  approved_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, contact_uid)
);
