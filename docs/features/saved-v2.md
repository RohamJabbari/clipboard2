# Saved v2 (1.7): one Saved, fewer chips, group chip morph

This follows `docs/features/folders.md` and changes it where the two disagree. Mac and Windows build the same thing.

## 1. Bug: clicking empty space closes the panel
- Clicking an empty part of the panel closes it on the Mac: the empty list area below the rows (for example the Saved tab with one folder), and probably the empty preview pane and header gaps.
- Likely cause: the empty SwiftUI regions aren't hit-testable, so the click falls through, the panel resigns key, and the close-on-resign logic runs.
- Fix: no click inside the panel's frame may close it. Use a `contentShape` on the list/scroll background, or handle it at the window level.
- Windows: check the same case against the delayed focus-loss check, and fix it if it applies.

## 2. Filter row
- The chips become **All · Saved · This App** (the `‹App name›` chip) **· Inbox** (only once there are contacts), then a divider, then the groups.
- Remove the **Text, Images, Files, Snippets and Secrets** chips.
- A stored filter value for a removed chip falls back to All.
- ⇥ cycling follows the new row, including both group segments (see §5).

## 3. Saved holds everything you keep
- Saved, in a space, lists:
  - **Folders** first.
  - Then the space's **saved clips, secrets and snippets**, mixed, newest first. Use `pinnedAt` or `lastCopiedAt` for clips, `createdAt` for secrets and `updatedAt` for snippets.
- **Secrets** show their existing masked row, with a **lock** icon as the row icon. Every existing secret action and safeguard is unchanged: reveal/paste auth, never sent to AI, never previewed with Quick Look. Remove Secret works as it does today.
- **Snippets** show with their existing snippet icon and keyword. Selecting one pastes or expands it as the Snippets chip did.
- Search from All still finds secrets and snippets, as today.

## 4. Folders hold secrets too, and group items can be saved to your folders
- **Secrets in folders:** the secret payload gets the same `folder` field as clips (see `docs/sync/PROTOCOL.md`; add `"folder"` to the secret payload and the backup secret entries). It follows the same rules: an unknown id means root, it's part of the fingerprint, and only the author or the owner can change it in a group.
  - Move to Folder, Remove from Folder and dragging all work on secrets.
  - Snippets don't go into folders. They stay at the Saved root of their space.
- **Secrets in groups:** they already sync to groups through Share to Group. A group's Saved lists that group's secrets and snippets. Check that this works end to end, don't assume it.
- **Move to Folder on a group item:**
  - The menu lists the group's own folders under a "‹Group›" header and your personal folders under "Mine".
  - Choosing a personal folder **saves a personal copy**: a new id in the personal space, saved, in that folder. The group item doesn't change.
  - The notice says "Saved a copy to ‹Folder›". New Folder… in the "Mine" section creates a personal folder and copies the item into it.
  - Multi-select works. Mixed spaces show only the "Mine" section.
  - This is the fix for "I have a folder but it doesn't show": the user selected group items, and only New Folder… was offered.
- **Add to Saved on another member's group item** (the server refuses that change): offer **Save a Copy** instead. It saves a personal copy at the personal Saved root, rather than a local-only pin that never syncs.
- **Share to Group…** on a personal clip, secret or folder keeps copying into the group. When the chosen group has folders, the share form also lets you pick one of them as the destination (default: the root).

## 5. Group chip morphs into Copies | Saved
- Remove the separate **All | Saved** row under the chips.
- When a group chip is selected, the chip itself grows, with an animation, into one pill: the group icon, the name, then two segments, **Copies** and **Saved**, for example `[👥 Softmaze | Copies · Saved]`.
- The selected segment has a highlight that slides between the two segments.
- Unselected group chips stay compact. Selecting another chip collapses the pill back the same way.
- Motion:
  - A spring of about 0.35 s with no overshoot: Mac SwiftUI `.spring(response: 0.35, dampingFraction: 0.9)` with a `matchedGeometryEffect` for the highlight; Windows a width/opacity animation with a cubic ease-out of about 250 ms.
  - Segment labels fade in after the pill starts to widen.
  - With Reduce Motion (Windows: animations off), there's no animation.
- Use the group's existing accent (magenta) for the pill, the active segment filled and the inactive one plain text, the same way the chip is styled today.
- Clicking the name area of an open pill does nothing new. Clicking a segment switches to it.
- The choice is remembered per group, as now.
- ⇥ goes from Copies to Saved to the next group.

## Not in scope
- Folders inside folders.
- Snippets inside folders.
- Live-linked shared folders.
- Changing the server's author-or-owner rule.
