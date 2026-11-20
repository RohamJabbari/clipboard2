# Notifications and the contact list (1.9)

Mac and Windows build the same thing. The server doesn't change: everything below is found by comparing what each sync brings with what was known before. Syncs run every 3–60 s, so notifications arrive within about a minute.

## Notifications
Use real system notifications: Mac `UNUserNotificationCenter`; Windows toast notifications that work for an unpackaged/Velopack app, with an AUMID on the Start-menu shortcut.

### Events
| Event | Title | Body | Click |
|---|---|---|---|
| Someone in a group shares an item | "‹Group›" | "‹Name› shared ‹short preview›". Images say "an image", files "‹file name›", secrets "a secret". Never the content of concealed or secret items | Opens the panel on that group with the item selected |
| Someone joins a group (accepted an invite code) | "‹Group›" | "‹Name› joined" | Opens that group |
| Someone leaves or is removed from a group you're in | "‹Group›" | "‹Name› left" | Opens that group |
| You were removed, or a group was deleted | "‹Group›" | "You're no longer in this group" | none |
| A group is renamed | "‹New name›" | "‹Old name› was renamed" | Opens that group |
| An incoming contact request | "Contact request" | "‹Name› wants to add you" | Opens the Contacts list (below) with the request on top |
| Your contact request was accepted, or someone used your contact code | "‹Name›" | "is now your contact" | Opens Contacts |
| A contact sends you something | "‹Name›" | "sent ‹short preview›" | Opens the Inbox with it selected |
| An authenticator is shared with you, or ownership is transferred to you | "‹Name›" | "shared ‹Issuer› codes with you" / "made you the owner of ‹Issuer›" | Opens Saved with it selected |

### Rules
- Never notify about your own actions, including those from your other devices.
- Never notify on the first sync after signing in, or after a reset. That sync records the current state only.
- Group items in one sync are batched per group and author: "‹Name› shared 5 items".
- Contact items are batched per contact.
- When the panel is open and showing that group or the Inbox, there's no notification: the item is already in view.
- These replace the HUD arrival notices for contacts that exist today. Keep the HUD only when notifications are off or not allowed.
- Notifications respect the system's Focus / Do Not Disturb (automatic with the system APIs).

### Settings
- Add a Notifications section to Settings with a master switch and one switch per kind: Group activity, Group members, Contacts, Authenticators.
- Each group gets **Mute notifications** in its right-click/actions menu, stored per group.
- Permission:
  - Ask for the system permission once, the first time an event would notify after updating, rather than at launch.
  - If it's denied, Settings shows "Notifications are off in System Settings" with a button to open them.
  - No custom dialogs.

## Contact list
- The **Inbox** chip becomes **Contacts**. It shows whenever you're signed in, even with no contacts yet. Inside it, a small segmented switch toggles **Inbox | People**, the same way the group pill does.
  - **Inbox** is what the Inbox shows today.
  - **People**:
    - A searchable list of your contacts. The search field matches name and username, and typing works the same as in the main search.
    - Pending requests come first: incoming ones with Accept and Decline, outgoing ones with Cancel.
    - Then contacts, sorted by most recently sent to or received from, then by name.
    - Each contact row has **Send…**, which picks items as in Add Items, and **Remove contact**, with an inline confirm.
    - **Add Contact** at the top takes a username or a code and offers Create Code. Reuse the existing flows from Settings.
- **Right-click → Send to Contact…** on any clip, secret (Touch ID first), folder (copies the subtree) or multi-selection replaces the flat per-contact menu entries.
  - It opens an inline picker in the right pane: a search field already focused, recent contacts first, ↑↓ and Return to send. ⌘↩ / Ctrl+Enter, or ticking several, sends to several contacts.
  - Notice: "Sent to ‹Name›".
  - The ⌘K list gets "Send to Contact…" too. Keep the top three recent contacts as direct "Send to ‹Name›" rows.
- Use the existing rules for what can't be sent: concealed items, secrets without auth, and items you received from a contact.

## Not in scope
- True server push (APNs/WNS). Polling is close enough for now.
- Inviting someone to a group by username. Groups still use invite codes.
- Notification actions such as Reply or Copy.
