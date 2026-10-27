-- October 2026 hardening (docs/sync/HARDENING-2026-10.md): invite-only sign-up, a session id per
-- device, and auth rate limits that hold across instances.

-- Sign-up codes. Only SHA-256 of the normalised code is stored. created_by is NULL for codes an
-- operator issued (scripts/signup-code.ts).
CREATE TABLE signup_codes (
  id         uuid PRIMARY KEY,
  code_hash  bytea NOT NULL UNIQUE,
  created_by text REFERENCES users (uid) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  used_by    text REFERENCES users (uid) ON DELETE SET NULL
);
CREATE INDEX signup_codes_open ON signup_codes (created_by, expires_at) WHERE used_at IS NULL;

-- A public id per session, so a device can be listed, revoked and addressed without its token.
ALTER TABLE sessions ADD COLUMN id uuid NOT NULL DEFAULT gen_random_uuid();
CREATE UNIQUE INDEX sessions_id ON sessions (id);

-- Fixed one-minute windows for prelogin, signup and login. key is an HMAC of "ip:…" or "email:…",
-- so the table holds no addresses.
CREATE TABLE auth_attempts (
  key          bytea NOT NULL,
  window_start timestamptz NOT NULL,
  hits         integer NOT NULL,
  PRIMARY KEY (key, window_start)
);
CREATE INDEX auth_attempts_window ON auth_attempts (window_start);
