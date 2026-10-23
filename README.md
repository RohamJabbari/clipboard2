# Clipboard2

A native macOS clipboard manager: menu bar app, Spotlight-style quick panel, snippets,
keychain-backed secrets, paste-time transforms and AI actions. Swift 6, SwiftUI first,
AppKit only where SwiftUI can't do the job. Requires macOS 14+; uses Liquid Glass on macOS 26.

## Install / rebuild

```sh
make install     # xcodegen → Release build → quit running copy → /Applications → launch
make test        # unit tests (Swift Testing)
make debug       # Debug build (bundle id at.softmaze.Clippy.debug, separate data)
make icon        # regenerate the app icon set from scripts/make-icon.swift
```

Needs Xcode 26 and `xcodegen` (`brew install xcodegen`). `project.yml` is the source of
truth; the `.xcodeproj` is generated and git-ignored. Signing uses the Apple Development
identity of team `XWTH2647FF` (not ad-hoc) so the Accessibility grant survives rebuilds.

## Windows version

`windows/` is a native Windows 10/11 app (C#, .NET 10, WPF with the Windows 11 Fluent theme) with
the same features, sharing no code with the Mac app but following it one to one:

| Mac | Windows |
|---|---|
| ⇧⌘V quick panel | **Ctrl+Shift+V** |
| ⌥⌘K actions on selection | **Ctrl+Alt+K** |
| ⌥⇧⌘V paste as text (OCR) | **Ctrl+Alt+Shift+V** |
| ⌥⇧⌘2 capture text | **Ctrl+Alt+Shift+2** (Snipping Tool + on-device OCR) |
| ⌘-right-click menu | **Ctrl+right-click** |
| ⌘1–9 / ⌘⇧1–9 quick slots | **Ctrl+1–9 / Ctrl+Shift+1–9** |
| ⌥⏎ plain text | **Shift+Enter** |
| Keychain | Windows Credential Manager |
| Touch ID | Windows Hello |
| Menu bar popover | Tray icon flyout |
| Sparkle | Velopack (Setup.exe installer + in-place updates) |
| Services menu | — (Windows has no equivalent) |

Layout: `src/Clipboard2.Core` (all logic — store, dedupe, retention, search, transforms,
snippets, AI clients, panel model; unit-tested on any OS), `src/Clipboard2.App` (Windows UI and
system hooks), `tests/Clipboard2.Core.Tests`.

```sh
make windows-test                       # unit tests (needs .NET 10; runs on macOS too)
make windows-release VERSION=1.1.0      # tag → GitHub Actions builds Setup.exe, publishes, updates feed
```

Data: `%LOCALAPPDATA%\Softmaze\Clipboard2` (history, images, log), settings in
`%APPDATA%\Softmaze\Clipboard2\settings.json`, keys and secrets in Credential Manager.
The installer isn't code-signed yet, so SmartScreen asks once ("More info → Run anyway").

## Installer

```sh
make pkg         # → dist/Clipboard2-<version>.pkg
```

A standard macOS Installer package: welcome page, installs to /Applications (replacing an
older copy), quits a running Clipboard2 first and launches the new one, ends with the shortcuts.

### Distribution (Developer ID)

To install without Gatekeeper warnings on other Macs, the app and package must be signed with
Developer ID and notarized. One-time setup (needs the Apple Developer account holder):

1. Xcode → Settings → Accounts → your team → Manage Certificates → **+** →
   *Developer ID Application*, then **+** → *Developer ID Installer*.
2. Create an app-specific password at account.apple.com → Sign-In and Security, then store it:
   `xcrun notarytool store-credentials clipboard2-notary --apple-id <you> --team-id XWTH2647FF`
3. `make pkg` now signs, notarizes and staples automatically; `make install` also switches to
   Developer ID so local and packaged builds share one signature.

After the switch, macOS asks once more for Accessibility (and Keychain access to existing
API keys/secrets), because those grants are tied to the signing certificate.

## Using it

| Where | Keys |
|---|---|
| Open quick panel | **⌘⇧V** (change in Settings → General; where it opens from — top, bottom, left, right or center — in Settings → Appearance) |
| Navigate / paste | ↑ ↓, **Return** pastes into the app you came from, **⌥Return** pastes as plain text |
| Quick slots | **⌘1–9** paste the item bound to that slot (or the Nth row if the slot is empty); **⌘⇧1–9** binds the selection |
| Actions | **⌘K**: transforms, AI actions, Save as Secret, pin, delete |
| Multi-select | **⌘-click** toggles, **⇧-click** selects a range, **⇧↑/⇧↓** extend, **⌘A** selects all (empty search); Return pastes them all, text joined by line breaks |
| Selected text, any app | **⌥⌘K**: transform it or ask AI; Return replaces the selection (also right-click → Services → Clipboard2 Actions…) |
| Text from screen | **⌥⇧⌘2**: drag over anything; the text is recognised on-device and pasted |
| Right-click menu | **⌘-right-click** anywhere: Clipboard2 items (text from image, actions on selection, recent, snippets, secrets, search) + Cut/Copy/Paste/Select All/Select Word/Look Up/Undo/Redo, Finder items in Finder, and “Show ‹App› Menu” for the app's own menu |
| Paste as text | **⌥⇧⌘V**: plain text; if the clipboard holds an image or screenshot, the text in it (on-device OCR). Clipboard is restored afterwards. In native apps also Services → *Paste Text from Clipboard Image* |
| Other | **⌘P** pin, **⌫** delete (history only), **Tab** cycles filters, **Esc** closes |

Filters: All, Pinned, Text, Images, Files, Snippets, Secrets, This App (items copied from the
app you were in when you opened the panel).

**Auto-paste** needs Accessibility access (System Settings → Privacy & Security →
Accessibility → Clipboard2). Without it Clipboard2 copies the item and you press ⌘V yourself.

**Secrets** are for things like a database password you paste many times a day. Add them in
Settings → Secrets, or select a copied value in the panel and choose ⌘K → Save as Secret
(which also removes it from history). Pasting asks for Touch ID once per unlock window
(default 15 min, ends on sleep/lock); "Leave Unlocked For…" (15 min – 1 week) unlocks
once with Touch ID and survives sleep/lock until it runs out or you press Lock Now, marks the clipboard as concealed so no clipboard
manager records it, and clears it again after 30 s. Bind a secret to a quick slot and give
the slot a global shortcut to paste it from any app without opening the panel.

**Snippets** support `{date}`, `{time}`, `{clipboard}`, `{cursor}` and custom fields like
`{name}`, which prompt for a value before pasting.

**AI actions** (Translate EN/DE/FA, Summarize, Fix Grammar, Explain, custom prompts) run
through the provider chosen in Settings → Actions:

- Anthropic (Claude API, default `claude-sonnet-5-5`)
- OpenAI, DeepSeek, OpenRouter, any OpenAI-compatible endpoint (Ollama, LM Studio, Groq…)
- Claude subscription (default): click "Sign in with Claude" in Settings → Actions (and "Set Up Claude" if
  Claude Code isn't installed). It drives Anthropic's own Claude Code login, then runs `claude -p`.
  No API key or API billing, but slower to start. Clipboard2 never borrows a subscription token
  itself; that would break Anthropic's terms.

Model IDs aren't hardcoded beyond defaults: "Fetch Models" reads each provider's `/models`.

## Where data lives

| What | Where |
|---|---|
| History database (SwiftData) | `~/Library/Application Support/at.softmaze.Clippy/Clipboard2.store` |
| Images and thumbnails | `~/Library/Application Support/at.softmaze.Clippy/Blobs/` |
| Settings, ignore list, slots | `UserDefaults` (`at.softmaze.Clippy`) |
| API keys | login Keychain, service `at.softmaze.Clippy.anthropic` |
| Secrets | login Keychain, service `at.softmaze.Clippy.secrets` |

## Architecture

```
Clipboard2/
  App/            Clipboard2App (MenuBarExtra + Settings scenes), AppEnvironment (owns all
                  services, shared paste flows, URL hooks), SettingsOpener, AppPaths/Log
  Models/         ClipItem + Snippet (@Model), RawCapture/ProcessedCapture, AppRef
  Services/
    ClipboardMonitor   polls NSPasteboard.changeCount every 0.5 s (Timer with tolerance);
                       ClipboardFilter decides capture vs skip; PasteboardReader reads types
    CaptureProcessing  @concurrent hashing (SHA-256), PNG + thumbnail encoding, blob writes
    ClipStore          dedupe-by-hash (moves to top), pin, delete, retention, orphan cleanup
    PasteService       pasteboard writes (marked so we don't re-capture), CGEvent ⌘V,
                       concealed secret writes with auto-clear
    Transform          pure text transforms; JSONFormatter keeps key order
    SnippetExpander    placeholder parsing/expansion (pure)
    AI                 providers, streaming clients (Anthropic SSE, OpenAI SSE, Claude Code
                       stream-json), Keychain, AIRun
    Secrets            SecretVault (Keychain CRUD), SecretStore (Touch ID gate, unlock window)
    QuickSlots         ⌘1–9 bindings + global slot shortcuts (KeyboardShortcuts)
    FrontmostAppTracker  remembers the last non-Clipboard2 app (paste target, "This App")
  UI/
    MenuBar/      popover (recent 200 + pinned, search, pause/clear/settings/quit)
    Panel/        QuickPanelController (non-activating NSPanel, NSGlassEffectView on 26,
                  NSVisualEffectView before; local key monitor), PanelViewModel (modes:
                  browse / actions / snippet form / save secret / AI), views
    Settings/     General (+ quick slots), Appearance, Ignored Apps, Snippets, Secrets,
                  Transforms, AI, Sync, About
```

Design notes:

- **Never captured:** `org.nspasteboard.ConcealedType`, `TransientType`, `AutoGeneratedType`,
  anything Clipboard2 wrote itself (`at.softmaze.clippy.internal`), and copies from ignored apps
  (prefilled with 1Password, Bitwarden, Keychain Access, Passwords).
- **Dedupe:** text and rich text share a hash namespace, so the same words with or without
  formatting are one item; recopying bumps `lastCopiedAt` and keeps the richer formats.
- **Retention:** max age (15 min – 1 year or never, default 30 days, counted from the last
  copy) and max items (default 500, or unlimited); pinned, labelled and slot-bound items
  and secrets are exempt. Runs after each capture and every minute.
- **Labels:** pinned items can carry a label shown above their value and matched by search;
  labelling pins. Secrets show their name and a masked value with Touch ID "Show".
- **Non-activating panel:** the frontmost app keeps focus, so ⌘V lands where you were typing.
- **Concurrency:** default MainActor isolation (Swift 6.2); hashing and image work run
  `@concurrent` off the main actor; nothing blocks the main thread on capture.
- **Memory:** a 700-capture stress run on a private pasteboard stayed flat at 18–20 MB.
- **Debug hooks** (Debug builds only): `clippy://snapshot?path=…` renders the panel to PNG,
  `clippy://stress?count=N` drives captures through a private pasteboard.
  `clippy://settings`, `clippy://panel`, `clippy://accessibility` work in all builds.

## Not done yet

- Phase 5 (end-to-end encrypted sync + PWA) is waiting on a schema/security-rules review.
- Live AI calls weren't exercised from the build machine (no key there); request shapes and
  stream parsing are unit-tested.
