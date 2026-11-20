# Folders in folders (1.8)

This extends `docs/features/folders.md` and `saved-v2.md`. Mac and Windows build the same thing.

## Data
- The folder payload gains `"parent":"<folder item id>"`. Leave it out for a top-level folder.
- The parent must be a folder in the same space.
- A folder with an unknown parent (deleted, or not pulled yet) shows at the top level. It moves under the parent once that arrives.
- Guard against cycles from concurrent edits: walking up the parents, a folder that meets itself or goes deeper than 8 levels is treated as top level.
- The UI never creates a cycle or anything deeper than 8 levels.
- `parent` is part of the folder fingerprint.
- Backups: folder entries carry `parent`. On import, folders join by name *within the same parent* and are created parents-first.
- Folders from 1.6/1.7 have no `parent`, so they stay top level.
  - Older clients show nested folders at the top level.
  - If an older client re-pushes a folder, it drops `parent` and the folder moves to the top. That's short-lived, because installs auto-update.

## Browsing
- An open folder lists its subfolders first, sorted by name, then its items in the existing order.
- A folder row's caption counts both: "3 folders · 12 items". Leave out a zero part.
- The breadcrumb shows the full path: "Saved › Work › Clients". Every segment can be clicked, and every segment is a drop target.
- Esc, ← or Backspace with empty search goes up **one** level.
- **New Folder** inside an open folder creates a subfolder there.
- Search from the Saved root (or from inside a folder) searches that folder's whole subtree. Each result's caption shows its path relative to where you are, such as "Work › Clients".

## Moving things
**Right-click menu on an item** (clip or secret), single or multi-select: **Move to Folder ▸**
- The submenu is hierarchical:
  - Each folder with subfolders is itself a submenu.
  - Its first entry is **"‹Folder›"**, which moves into that folder itself, followed by a separator and its children.
  - A folder without children is a plain item.
  - **New Folder…** comes last at each level, and creates the folder at that level.
- When the item is already in a folder, **Move to Top Level** is offered. It replaces "Remove from Folder".
- The group and "Mine" sections from saved-v2 stay. Each one is a tree.

**⌘K actions list:**
- Flat rows, one per folder: "Move to Work › Clients".
- Typing filters them.

**Right-click menu on a folder:**
- **Move to Folder ▸**: the same tree, without the folder itself and its descendants.
- **Move to Top Level** when the folder is nested.
- Plus the existing actions: Open, Rename, Label, New Folder Inside, Share to Group…, Delete.

**Dragging:**
- Items can be dragged onto folder rows and breadcrumb segments, as now.
- **Folder rows can be dragged too**: onto another folder row to nest, or onto a breadcrumb segment to move up.
- An invalid target (itself or a descendant) doesn't highlight and refuses the drop.

## Deleting
- Deleting a folder moves its items **and subfolders** up to its parent, or to the root if it has none.
- The notice says "Folder deleted · moved N items to ‹Parent›".
- Nothing is lost and there's no dialog.

## Sharing and copying
- **Share to Group…** on a folder copies the whole subtree into the chosen group: new ids, the structure kept, secrets included (with one Touch ID / Windows Hello prompt).
- The destination picker (root, or one of the group's folders) shows the group's tree.
- Saving a group item into a personal folder ("Mine") goes through the same tree picker.

## Permissions
These are unchanged: in a group, only an item's author or the group's owner can change it, and that includes moving folders. Hide moves the server would refuse.
