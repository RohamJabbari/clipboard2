-- Optional display names so group members see who copied an item. Stored as typed, unique
-- case-insensitively; accounts from before this migration have none (NULL).

ALTER TABLE users ADD COLUMN username text;
CREATE UNIQUE INDEX users_username ON users (lower(username));
