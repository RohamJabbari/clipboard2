import SwiftUI

/// The privacy notice (Art. 13 GDPR) and the legal notice (Impressum, § 5 ECG / § 25 MedienG).
/// The operator is a private person. `[ADDRESS]` and `[CONTACT EMAIL]` are placeholders that must
/// be filled in before release.
nonisolated enum LegalText {
    static let operatorName = "Roham Jabbari"
    static let address = "[ADDRESS]"
    static let country = "Austria"
    static let email = "[CONTACT EMAIL]"
    static let lastUpdated = "October 2026"

    struct Section: Identifiable, Sendable {
        let title: String
        let body: String
        var id: String { title }
    }

    static let privacy: [Section] = [
        Section(title: "Who is responsible", body: """
        \(operatorName), \(address), \(country) — a private person who develops and runs Clipboard2 and its sync service. \
        Contact for anything about your data: \(email).
        """),
        Section(title: "Without an account", body: """
        Your history, snippets, secrets and settings stay on this Mac. Secrets are kept in your Keychain. Text in \
        images and screenshots is recognised on this Mac. Nothing is sent to us.

        To check for updates, Clipboard2 downloads a small file from GitHub about once an hour. GitHub (in the USA) \
        sees your IP address and the app version, as with any download.
        """),
        Section(title: "What sync stores, and why", body: """
        Sync is optional. If you create an account, we store:
        • your email address and username (to sign you in and to show your name to people in your groups);
        • your clipboard items, snippets and secrets, and the names of your groups — all encrypted on your device \
        before upload;
        • technical data the service needs to work: when items were created and changed, their size and type, who \
        wrote them, group membership and roles, your devices' names and when each was last used, and a login \
        verifier derived from your password (never the password itself).

        We use this only to provide sync and group sharing (Art. 6(1)(b) GDPR — the service you asked for) and to \
        keep it secure, for example to limit repeated login attempts (Art. 6(1)(f) — our interest in a safe \
        service). Our own request logs record neither IP addresses nor email addresses; Google Cloud's platform \
        logs can contain IP addresses and are kept for up to 30 days. There is no advertising, tracking or \
        analytics, and your data isn't sold or shared for marketing.
        """),
        Section(title: "We can't read your clipboard", body: """
        Items, snippets, secrets and group names are encrypted on your device with keys that come from your \
        password. The server only ever holds the encrypted data, so neither we nor our hosting provider can read \
        what you copied. The downside: if you forget your password, we can't recover your data.
        """),
        Section(title: "Where it's stored", body: """
        On Google Cloud in the europe-west1 region (Belgium, EU). Google Cloud EMEA Limited processes the data on \
        our behalf under its data processing terms. Google may support the service from outside the EU; such \
        transfers are covered by the EU Standard Contractual Clauses and the EU–US Data Privacy Framework.
        """),
        Section(title: "How long we keep it", body: """
        As long as you have an account. Group history keeps only its newest items; older ones are removed \
        automatically. Something you delete is removed from the server, and other devices only learn that it was \
        deleted. When you delete your account, your account, devices and everything you stored — including what \
        you added to groups — is deleted from the service straight away.
        """),
        Section(title: "Deleting your account", body: """
        Settings → Sync → Delete Account. You'll confirm with your password. Your local history on this Mac stays \
        until you clear it.
        """),
        Section(title: "AI actions (only if you turn them on)", body: """
        AI is off until you set it up. When you run an AI action, the selected text or image goes directly from \
        this Mac to the provider you chose — Anthropic, OpenAI, Google, DeepSeek, Groq, xAI, Mistral, OpenRouter, \
        your own endpoint, or the Claude or ChatGPT (Codex) app signed in to your account. We never receive it. \
        The provider handles it under its own privacy terms, and some are outside the EU (for example in the USA \
        or China). Don't send anything you wouldn't want that provider to see.
        """),
        Section(title: "Your rights", body: """
        You can ask for access to your data (Art. 15 GDPR), correction (Art. 16), deletion (Art. 17), restriction \
        (Art. 18) and a copy to take elsewhere (Art. 20), and object to processing based on our legitimate \
        interest (Art. 21). Write to \(email). Because your content is encrypted, only your own devices can show \
        it; Settings → General → Back up exports it in readable form for you.

        You may also complain to the Austrian Data Protection Authority (Datenschutzbehörde, Barichgasse 40–42, \
        1030 Vienna, dsb.gv.at) or the authority where you live.
        """),
        Section(title: "Do you have to provide data?", body: """
        Only to use sync: without an email address and password we can't create an account. Everything else in \
        Clipboard2 works without one. No automated decisions are made about you.
        """),
    ]

    static let impressum: [Section] = [
        Section(title: "Media owner and service provider", body: """
        Medieninhaber und Diensteanbieter (§ 5 ECG, § 25 MedienG):
        \(operatorName)
        \(address)
        \(country)
        Email: \(email)
        """),
        Section(title: "About this app", body: """
        Clipboard2 is a clipboard manager for Mac and Windows, with optional end-to-end-encrypted sync, run by a \
        private person. Grundlegende Richtung: information about Clipboard2 and the operation of its sync service.
        """),
    ]
}

/// A scrolling document of titled sections, used for both notices.
struct LegalDocumentView: View {
    let title: String
    let sections: [LegalText.Section]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.title2.weight(.semibold))
                        Text("Last updated \(LegalText.lastUpdated)").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            Text(section.body)
                                .font(.callout)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 560)
    }
}

/// "Privacy Notice · Legal Notice" for the bottom of Settings → General.
struct LegalLinks: View {
    @State private var showing: Document?

    enum Document: String, Identifiable {
        case privacy, impressum
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button("Privacy Notice") { showing = .privacy }
            Text("·").accessibilityHidden(true)
            Button("Legal Notice (Impressum)") { showing = .impressum }
        }
        .buttonStyle(.link)
        .font(.caption)
        .foregroundStyle(.secondary)
        .sheet(item: $showing) { document in
            switch document {
            case .privacy: LegalDocumentView(title: "Privacy Notice", sections: LegalText.privacy)
            case .impressum: LegalDocumentView(title: "Legal Notice", sections: LegalText.impressum)
            }
        }
    }
}

/// For the sync sign-up form: "By creating an account you accept … Privacy Notice".
struct PrivacyNoticeLink: View {
    @State private var showing = false

    var body: some View {
        HStack(spacing: 4) {
            Text("How your account data is handled:")
            Button("Privacy Notice") { showing = true }
                .buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .sheet(isPresented: $showing) {
            LegalDocumentView(title: "Privacy Notice", sections: LegalText.privacy)
        }
    }
}
