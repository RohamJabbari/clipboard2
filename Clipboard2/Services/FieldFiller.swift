import AppKit
import ApplicationServices

/// Types into another app's focused field with synthetic key events, so nothing goes through the
/// clipboard or into history. When another app holds Secure Event Input (typing wouldn't arrive),
/// each value goes in by a concealed, transient paste instead, which clipboard managers skip.
@MainActor
struct FieldFiller {
    let paste: PasteService
    /// How long a fallback paste stays on the clipboard.
    var clearAfter = 30

    /// Activates the target, then runs the steps.
    func run(_ steps: [FillStep], into target: NSRunningApplication?) async {
        guard !steps.isEmpty else { return }
        guard AXPermission.isTrusted else {
            // No Accessibility: the last value lands on the clipboard (concealed) for a manual ⌘V.
            if case .type(let text)? = steps.last(where: { if case .type = $0 { true } else { false } }) {
                paste.pasteSecret(text, into: target, clearAfter: clearAfter)
            }
            return
        }
        if let target, !target.isActive {
            target.activate()
            try? await Task.sleep(for: .milliseconds(120))
        }
        let typing = FillPlanner.canType(secureInputPID: Self.secureInputPID(), targetPID: target?.processIdentifier)
        for step in steps {
            switch step {
            case .tab:
                PasteService.postKey(48, flags: [])          // kVK_Tab
                try? await Task.sleep(for: .milliseconds(150))
            case .type(let text):
                if typing {
                    await Self.type(text)
                } else {
                    paste.writeSecret(text, clearAfter: clearAfter)
                    PasteService.postKey(9, flags: .maskCommand)   // kVK_ANSI_V
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
    }

    /// Focuses `element` in the target app and types `text` there (Fill Form, confirm fields).
    func fill(_ element: AXElement, with text: String, in target: NSRunningApplication?) async {
        if !FieldAX.focus(element) {
            FieldAX.setValue(text, of: element)
            return
        }
        try? await Task.sleep(for: .milliseconds(80))
        await run([.type(text)], into: target)
    }

    /// One key event per character, each carrying its text (works whatever the keyboard layout).
    static func type(_ text: String) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        for (index, character) in text.enumerated() {
            let units = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            for event in [down, up] {
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.setIntegerValueField(.eventSourceUserData, value: PasteService.syntheticEventMarker)
                event.post(tap: .cgSessionEventTap)
            }
            // A short breath now and then, so web pages' key handlers keep up.
            if index % 8 == 7 { try? await Task.sleep(for: .milliseconds(6)) }
        }
    }

    /// The process holding Secure Event Input, if any.
    static func secureInputPID() -> Int32? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
    }
}

// MARK: - Suggest Strong Password, for real

/// Fills the password field the paste icon sits in, and the confirm field after it.
@MainActor
struct LivePasswordFieldFiller: PasswordFieldFilling {
    let filler: FieldFiller
    let field: AXElement
    let target: NSRunningApplication?

    func fillFocused(_ text: String) async {
        FieldAX.focus(field)
        await filler.run([.type(text)], into: target)
    }

    func fillConfirm(_ text: String) async -> Bool {
        guard let confirm = FieldAX.confirmField(after: field) else { return false }
        await filler.fill(confirm, with: text, in: target)
        return true
    }
}

extension SecretStore: PasswordSaving {
    func savePassword(name: String, value: String, username: String?, urls: [String]) -> SecretRef? {
        add(name: name, value: value, username: username, urls: urls)
    }

    func deletePassword(_ ref: SecretRef) {
        delete(ref)
    }
}

// MARK: - Fill from Auth and the paste icon

extension AppEnvironment {
    /// Touch ID, then fills the password (and the username, when the focused field is a username
    /// field followed by a password field). `remember`: add that site to the password first.
    func fillPassword(_ ref: SecretRef, into target: NSRunningApplication?, remember site: String? = nil) {
        let target = target ?? appTracker.targetApp
        Task {
            guard let value = await secrets.reveal(ref, reason: "fill the password for “\(ref.name)”") else { return }
            if let site {
                let urls = SiteMatch.remembering(ref.urls, site: site)
                if urls != ref.urls { secrets.update(ref, urls: urls) }
            }
            if let target, !target.isActive {
                target.activate()
                try? await Task.sleep(for: .milliseconds(150))
            }
            let focused = target.map { FieldAX.focusedFieldKind(pid: $0.processIdentifier) } ?? .unknown
            let steps = FillPlanner.plan(.password(username: ref.username, password: value), focused: focused)
            await FieldFiller(paste: paste, clearAfter: prefs.secretClearSeconds).run(steps, into: target)
            // Saved already: a paste of the same value right after doesn't offer to save it.
            if let target, let field = FieldAX.focusedElement(pid: target.processIdentifier), FieldAX.isSecure(field) {
                loginSaver.filled(value, field: field, in: target)
            }
        }
    }

    /// Types an authenticator or email code into the target's focused field.
    func fillCode(_ code: String, into target: NSRunningApplication?) {
        fillText(code, into: target)
    }

    /// Types a value (a code, a card's email…) into the target's focused field.
    func fillText(_ text: String, into target: NSRunningApplication?) {
        let target = target ?? appTracker.targetApp
        Task {
            await FieldFiller(paste: paste, clearAfter: Self.codeClearSeconds).run(FillPlanner.plan(.text(text), focused: .unknown),
                                                                              into: target)
        }
    }

    /// Fill Form: every empty field in the same web area whose kind the card answers.
    func fillForm(with card: PersonalCard, around field: AXElement, in target: NSRunningApplication?) {
        Task {
            let filler = FieldFiller(paste: paste)
            var filled = 0
            for element in FieldAX.formFields(around: field) where !FieldAX.isSecure(element) && FieldAX.isEmpty(element) {
                guard let kind = FormFieldGuesser.guess(FieldAX.hints(of: element)), let value = card.value(for: kind) else { continue }
                await filler.fill(element, with: value, in: target)
                filled += 1
            }
            FieldAX.focus(field)
            if filled == 0 { HUD.show("No fields to fill", symbol: "questionmark.circle") }
        }
    }

    /// Suggest Strong Password: fills it (and the confirm field), saves it for the page's site, and
    /// offers Undo.
    func suggestStrongPassword(_ password: String, field: AXElement, in target: NSRunningApplication?, site: String?) {
        Task {
            let context = PasswordFieldContext(site: site, username: FieldAX.usernameAbove(field))
            let filler = LivePasswordFieldFiller(filler: FieldFiller(paste: paste), field: field, target: target)
            let result = await StrongPasswordFlow.run(password: password, context: context, filler: filler, saver: secrets)
            if result.saved != nil { loginSaver.filled(password, field: field, in: target) }
            if result.saved == nil {
                HUD.show(result.notice, symbol: "exclamationmark.triangle.fill")
                return
            }
            ActionToast.show(result.notice, action: "Undo") { [secrets] in
                StrongPasswordFlow.undo(result, saver: secrets)
                HUD.show("Removed the saved password", symbol: "arrow.uturn.backward.circle.fill")
            }
        }
    }
}
