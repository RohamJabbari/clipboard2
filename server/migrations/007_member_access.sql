-- Group member access (docs/features/member-access.md, PROTOCOL.md "Member access"): per member, Send
-- (may add or change items and upload blobs) and Secrets (receives and may touch `secret` items). Only
-- groups enforce them; the owner's row always keeps both. Existing members keep both.

ALTER TABLE space_members ADD COLUMN can_send boolean NOT NULL DEFAULT true;
ALTER TABLE space_members ADD COLUMN can_see_secrets boolean NOT NULL DEFAULT true;
