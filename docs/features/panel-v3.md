# Quick panel v3 (Mac, 1.11)

Mac only. Windows follows later from this spec.

## 1. Size
- The panel is resizable by its edges and corners.
  - Minimum 640 × 400.
  - Maximum: the smaller of 1280 × 900 and 90% of the visible screen.
- First open on a screen: 60% of the visible width and 60% of its height, clamped to that range.
- The size is remembered and clamped again on a smaller screen.
- The preview pane and the list share the width as today (list 44%, preview 56%).
  - Under 760 pt wide, the preview pane narrows first, down to 260 pt. The list never goes under 320 pt.
- Remove Settings → Appearance → Panel size (compact/regular/large). A stored value only seeds the first size.

## 2. Moving the panel
- A **grip** (`line.3.horizontal`, vertical dots style, tertiary) sits left of the search icon. Dragging it moves the panel.
- Dragging anywhere in the top bar also moves it: the search row and the chip row, but not the search text field itself, buttons or chips.
- The position is remembered per screen. The next open appears there.
  - The open animation still plays, from the panel's new place.
  - If the remembered place is off the visible screen, it falls back to the panel-origin setting.
- Settings → Appearance gets **Reset Position**.

## 3. Keep Open
- Top right of the search row, right of "→ Pastes into ‹App›", there's a button: pin icon + **Keep Open**.
- Clicking it pins the panel.
  - The button turns accent-coloured and reads **Kept Open** (filled pin).
  - Clicking it again unpins.
- While pinned, the panel never closes by itself: not on paste, losing focus, clicking elsewhere, esc or ⇧⌘V.
  - esc still backs out of modes (actions, forms, folders) but doesn't close the panel at the top level.
  - ⇧⌘V brings it to the front and focuses search.
- Pasting while pinned:
  - Paste goes to the app that was frontmost before the panel took focus, as today.
  - After the paste, the panel stays visible without taking focus back, so you keep typing in the target app.
  - The "Pastes into" target follows whichever app you were last in.
- Pinned state is not remembered across launches.

## 4. Chips: Copies · Saved · Auth · Contacts · Groups
Replace All · Saved · ‹This App› · Contacts · ‹group chips›.

### Copies
- What you copied on your devices: your own history, synced between your devices.
- Never contact items or group items.
- It is the default chip.
- The ‹This App› chip goes away. Its filter lives on as a toggle in Copies' search field (the app icon, "Only from ‹App›").

### Saved
- Everything you saved (§6): clips, snippets and folders. Secrets move to Auth.
- **Folders expand in place (a tree)**, here and in a group's Saved. There's no "open folder" level or breadcrumb any more.
  - Each folder row has a disclosure chevron. Click, Return or → expands it; click, Return or ← collapses it.
  - An expanded folder's subfolders (by name), then its items, follow right under it, indented one step per level.
  - → on an expanded folder steps into its first row; ← on a row inside a folder selects that folder. ↑↓ walk the visible rows.
  - Collapsing a folder that holds the selection selects the folder.
  - Which folders are expanded is remembered per space (yours, each group) until the app quits.
  - Search flattens the tree: every match, captioned with its folder path. Picking a folder from the results clears the search and reveals it, expanded.
  - The folder preview offers **Expand/Collapse**, Rename… and Label….
  - **+** and **New Folder** go inside the selected folder when a folder row is selected, else to the top level; the new folder's parent expands.
  - The "Saved" title above the list is a drop target for "move to the top level". Dragging onto folder rows works as before.
- The header stays at the top of the list pane; an empty state sits right under it (every chip).

### Auth
- Passwords, secrets, authenticator codes and email codes, grouped by source. See `auth-autofill.md`.
- Opening Auth asks for Touch ID only to reveal or paste, not to list. Names, sites and usernames are listed.

### Contacts
- Unchanged (Inbox | People).

### Groups
- One chip. Inside it, a group switcher row shows each group as a pill, in the same style as today's group chip.
- Copies | Saved for the selected group stays the same.
- The last group is remembered.
- Without groups, the chip shows the join or create empty state.

### Migration and other behaviour
- Tab cycles the five chips.
- A stored filter that no longer exists falls back to Copies.
- Search in Copies covers only Copies. Search from Auth covers only Auth. Each chip searches its own content.

### Where ⇧⌘V opens
- If something was copied into Copies since the panel last opened (a new item, or an older one copied again), it opens on **Copies**, search cleared, with that newest item selected and the list at the top. The first open after launch does the same.
- Otherwise it opens exactly where you left it: chip, group (and its Copies | Saved), search text, expanded folders, selected row and scroll position.
  - Deleting the newest copy doesn't count as a new copy.
  - "Only from ‹App›" stays on only if the panel pastes into the same app as last time.
- Modes (⌘K, forms) never carry over: the panel always opens on the list.

## 5. Preview (⌘Y)
- **Bug:** ⌘Y on some items shows Quick Look's "No item selected". Quick Look only gets URLs for non-transient clips with files. Text, rich text, colours, links and images without a file give it nothing.
- **Fix:** every previewable entry gets a file.
  - text, rich text and links: a temporary `.txt` / `.rtf` / `.webloc`
  - images: a `.png`
  - colours: a small `.png` swatch
  - Secrets and authenticators are never previewed. ⌘Y beeps on them.
- Quick Look opens centred over the panel, not in a screen corner.
  - Set its frame before showing it: centred on the panel, at most 80% of the visible screen.

## 6. Save replaces Add Label and Move to Folder
- In the row menu, ⌘K and the preview pane, **Label…**, **Add Label**, **Move to Folder** and **Add to Saved** become one action: **Save…** (⌘S).
- For an item that's already saved, it reads **Edit Saved…**. It uses the same form, prefilled.
- **Remove from Saved** stays.
- The form, inline in the right pane (no dialog):
  - **Label:** prefilled with the item's existing label, or else its first line of text, trimmed to 60 characters. For images and files, the file name or "Image". The label can be edited, and an empty label is allowed.
  - **Search** field, one for both lists: it filters folder names and group names in both lists at once.
  - **Two lists side by side:**
    - **Left, "My folders":** your folder tree (indent per level), with "Saved (no folder)" first.
    - **Right, "Group folders":**
      - A group filter pill row on top (All groups, or one group).
      - Each group's root ("‹Group›") and its folder tree.
      - Groups you can't send to aren't listed.
  - Picking a row selects that destination. There is exactly one destination.
  - Return / **Save** saves.
- What saving does:
  - **Into your Saved:** pin, set the label and set the folder. It's a copy if the item is a group or contact item, as "Save a Copy" does today.
  - **Into a group:** share a copy into that group and folder (Share to Group), with the label.
  - Multi-select: the label field is hidden and every selected item goes to the destination.
- **New Folder** at the bottom of each list creates a folder in the selected level and selects it.

## 7. Paste part of a text
- The preview pane's text is selectable. That covers clips and the recognised text of images.
- While text is selected there:
  - Return and the Paste button paste **only the selection**, as plain text. The button reads **Paste Selection**.
  - ⌘C copies the selection.
  - Clicking elsewhere or changing the row clears the selection.
- A partial paste doesn't add a new history item, and it doesn't change the clip.
