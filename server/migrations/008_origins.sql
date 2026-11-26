-- Origins (docs/sync/PROTOCOL.md, "Origins"): a site in Auth edited by hand (its name, domains, icon,
-- notes and documents). Encrypted like every item, in their own category so older clients skip them.
-- Only the personal space holds them (checked by the API).
ALTER TABLE items DROP CONSTRAINT items_category_check;
ALTER TABLE items ADD CONSTRAINT items_category_check
  CHECK (category IN ('history', 'pinned', 'snippet', 'secret', 'folder', 'otp', 'origin'));
