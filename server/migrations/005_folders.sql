-- Folders: encrypted like every item, in their own category so older clients skip them.
ALTER TABLE items DROP CONSTRAINT items_category_check;
ALTER TABLE items ADD CONSTRAINT items_category_check
  CHECK (category IN ('history', 'pinned', 'snippet', 'secret', 'folder'));
