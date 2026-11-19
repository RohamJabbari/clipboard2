# Saved, folders and group Saved (1.6)

Mac and Windows build the same thing. The wire format is in `docs/sync/PROTOCOL.md` (search for "Folders").

## Rename: Labelled → Saved
- The filter chip "Labelled" becomes **Saved** (Mac symbol `bookmark`). It still shows `isPinned` items.
- "Remove from Labelled" becomes **Remove from Saved**.
- New action **Add to Saved** for an unsaved clip (single or multi-select). It pins the clip without a label.
- Labels stay exactly as they are: a label belongs to an item, labelling still saves it, and removing a label still unsaves it unless the item is in a folder or a quick slot.
- Rename the user-facing strings only. Internal names such as `isPinned`, the `pinned` category and the `labelled` raw values may stay, so stored settings keep working.

## Folders
- A folder has a name, an optional label (same label UI as items) and `createdAt`/`updatedAt`.
- It lives in one space: your personal space, or a group.
- Folders are one level deep: they hold clips, not other folders.
- Use the name `ClipFolder` in code. `FolderSaver` and `FolderArchive` (saving to disk, zipped file folders) already exist and are unrelated.
- Being in a folder implies saved:
  - Moving a clip into a folder sets `isPinned`.
  - Moving it out, by dragging or **Remove from Folder**, leaves it saved at the Saved root.
  - **Remove from Saved** also clears the folder.
- Deleting a folder moves its clips to the Saved root. Nothing is lost, there's no confirmation dialog, and a HUD/notice says "Folder deleted · N items moved to Saved".

### Saved tab layout
- At the root:
  - Folder rows come first, sorted by name. Each row shows a folder icon, the name, the label tag if any and the item count.
  - Saved clips without a folder follow, in the existing order.
- Opening a folder:
  - Click or Enter on a folder row opens it.
  - The header shows a breadcrumb, "Saved › Name", and the list shows only that folder's clips.
  - Esc, ← (Mac) / Backspace (when the search field is empty) or clicking "Saved" in the breadcrumb returns to the root. Esc in a folder goes back; it doesn't close the panel.
- Searching from the Saved root searches every saved clip, including clips in folders. A result inside a folder shows the folder name as a small caption.
- A **New Folder** button in the Saved header creates "New Folder" and starts an inline rename.

### Moving clips
- Drag one or more clips onto a folder row to move them in. Highlight the row while it's a drop target.
- Inside a folder, dragging clips onto the "Saved" breadcrumb moves them out.
- Dragging from History/All onto a folder row only works while the Saved tab is showing, so it's enough to support drags that start in the panel list.
- Actions on clips (single or multi-select), in the panel actions list and the right-click menu:
  - **Move to Folder ▸** lists the folders of the clip's space, plus **New Folder…** (creates one, named from an inline prompt, and moves the selection in). This covers "I copied 5 related things": select them in History and use Move to Folder ▸ New Folder….
  - **Remove from Folder** appears when the clip is in a folder.
- Clips can only move into folders of their own space. Moving a personal clip into a group folder means sharing it, so offer that only through Share to Group.

### Folder actions
These are on a folder row's actions and right-click menu:
- **Open**
- **Rename**: inline.
- **Label…**
- **Share to Group…**: the existing group picker. It copies the folder (new id, same name and label) and copies of its clips (new ids, saved, in the new folder) into the chosen group, using the existing share-to-group copy path. The personal folder stays as it is, and later changes don't propagate. Not offered for folders that are already in a group.
- **Delete Folder**

## Groups
- When a group chip is selected, show a small **All | Saved** segmented switch under the filter row, and remember the choice per group.
  - **All** is what the group shows today.
  - **Saved** is the same Saved layout as above, scoped to that group's saved clips and folders.
- **Add to Saved**, folders, moving, labels and Delete Folder all work on group items and sync to every member. That's already true for pins in group spaces; check it, don't assume it.
- Any member can create, rename, label or delete a group folder, the same as any member can delete a group item today.
- **Remove from Group**: on a group item, the delete action reads "Remove from Group". It deletes the item for everyone, as group delete does today. Multi-select works.
- The personal Saved tab doesn't show group folders.

## Contacts / Inbox
Folders aren't sent to contacts in v1. Received contact items can't be moved into folders, because edits to received items stay local. Hide Move to Folder for those items.

## Sync (both clients)
- Store folders locally with a `spaceID`, like items.
- Push them as category `folder` (sortAt = createdAt) and pull, decode and delete them like snippets.
- Add the clip payload field `folder` and include it in the canonical payload fingerprint, so moving a clip re-pushes it.
- Tolerate a clip whose `folder` id is unknown: it shows at the root.
- If the folder arrives later, the clip moves into it.
- Deleting a folder:
  - Push the folder's tombstone.
  - Clear `folder` on the local clips that were in it, so they re-push without it.
- Retention: clips in folders are pinned, so the existing pinned retention applies. Make sure nothing trims them.
- Backups/export: include folders if the existing backup format can be extended compatibly; otherwise note it as a follow-up.

## Not in scope
- Nested folders.
- Folders for snippets or secrets.
- Sending folders to contacts.
- Live-linked shared folders.
