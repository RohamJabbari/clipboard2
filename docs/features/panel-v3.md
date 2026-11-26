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
- Folders work as today.

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

## 8. Copied files: contents, partial paste, edited copies (Mac, 1.13)
- **Contents.** When the previewed item is one file (or one file is picked of several), the preview shows the file's name field on top and, when the file is text, its contents below.
  - Text: a known text extension (`.txt .md .log .csv .tsv .json .xml .yaml/.yml .toml .ini .html .css .js/.ts .py .swift .java .go .rs .c/.h .sh .sql`… and anything `UTType` calls plain text, source code, JSON, XML, YAML, CSV or HTML) or, for other names, a file of up to 1 MB that is valid UTF-8 with no NUL bytes. UTF-16 with a BOM is read; Windows Latin 1 too for known extensions. RTF and Word files are not shown as raw bytes.
  - Prose (`.txt .md` and no extension) uses the system font; code and data are monospaced.
  - `.json` is shown pretty-printed only when it's valid (keys in their order), with a note that the file is unchanged. Invalid JSON is shown as it is.
  - Only the first 1 MB is read. A longer file shows that part with "Showing the first 1 MB of ‹size›"; it can't be edited.
  - A file clip keeps only the file's path. If nothing is there any more, the pane says so inline, with the path.
  - Files that look like keys or passwords are never shown: names like `.env`, `.env.*`, `.netrc`, `id_rsa`, `*.pem`, `*.key`, `*.p12`, and any text `SensitiveText` flags (a private key block, a single token). Folders, binaries and unreadable files show the icon and size.
- **Part of it.** The contents are selectable like §7: with a selection, Return pastes just the selection as plain text and ⌘C copies it. No history item is added.
- **Paste Selected Only.** For any selectable preview text — a text clip (also while editing it), the recognised text of an image, and file contents (PDF files show their icon: the app has no PDF text yet) — a non-empty selection shows an accent **Paste Selected Only** button at the top right of the preview (in a file's header, next to Edit). It pastes the selection as plain text and goes away when the selection clears. The footer keeps "⏎ Paste Selection".
- **Edit → new copy.** **Edit** in the file's header, ⌘E, or ⌘K → **Edit a Copy of the File** (text files up to 1 MB).
  - The contents become editable inline. The name field switches to `‹name›-edited.‹ext›`; if that name is already used by a file item in Copies, `-edited-2`, `-edited-3`… Editing an edited copy doesn't stack suffixes. A name typed before Edit is kept.
  - **Save as New Copy** (⌘S or ⌘Return) writes the text (UTF-8) to a new file in the app's own storage and adds it to Copies as a new file item, selected. The original item and file are untouched. Pasting the new item pastes the file under its name, as a file URL like any file clip.
  - **Cancel** discards. esc with unsaved edits first says so in the footer ("⌘S keeps a copy, esc discards"); a second esc discards. Choosing another row discards too.
  - While editing: plain text only, no smart quotes or autocorrect; ⌘A ⌘C ⌘X ⌘V ⌘Z work, and ⌘C copies as plain text without a history item.
- **Rename.** The name field is the name the item pastes with. Type a new name and press Return (or **Rename** / **Keep Renamed Copy**); ⌘K → **Rename File…** focuses it with the name selected without its extension. esc puts the name back.
  - A file Clipboard2 keeps itself (an edited copy, or a file that arrived through sync) in a personal item is renamed in place.
  - Any other file gets a renamed copy as a new item in Copies. The user's file on disk is never renamed or changed.
  - Slashes and colons become dashes; an empty name is refused with a beep.
- **Storage.** Kept files live in `Application Support/‹bundle id›/Synced Files/‹item id›/‹name›`, the folder sync already uses for received files: the file goes when its item is deleted, a group or personal copy gets its own copy, and orphaned folders are cleaned up.
- **Sync.** No new payload field. A kept file is a normal file clip whose file is uploaded as a `fileBlobs` entry; its name is the blob's `name`, so other devices (Windows ≥ 1.10.2 included) receive it under the edited name. A rename changes the path, so the file is uploaded again under the new name.
- Secrets and authenticators are never previewed, as before. Backups keep file paths only, as for any file clip.
