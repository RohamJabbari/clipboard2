import SwiftUI

/// One row of Auth: a password or secret, an authenticator (own or shared), or a code from a message.
enum AuthEntry: Identifiable {
    case secret(MobileSecret)
    case otp(MobileOTP)
    case shared(MobileSharedCodes)
    case code(SignInCode)

    var id: String {
        switch self {
        case .secret(let s): "s:" + s.id
        case .otp(let o): "o:" + o.id
        case .shared(let s): "c:" + s.id
        case .code(let c): "m:" + c.id.uuidString
        }
    }

    var title: String {
        switch self {
        case .secret(let s): s.payload.username ?? s.payload.name
        case .otp(let o): o.payload.account.isEmpty ? o.payload.issuer : o.payload.account
        case .shared(let s): s.batch.account.isEmpty ? s.batch.issuer : s.batch.account
        case .code(let c): c.sender ?? "Text message"
        }
    }

    var source: AuthSource? {
        switch self {
        case .secret(let s):
            return AuthSource.domains(ofSites: s.payload.urls ?? []).first.map(AuthSource.domain)
        case .otp(let o):
            return Self.source(urls: o.payload.urls ?? [], issuer: o.payload.issuer)
        case .shared(let s):
            return Self.source(urls: [], issuer: s.batch.issuer)
        case .code(let c):
            return c.domain.map(AuthSource.domain)
        }
    }

    /// Like the Mac: a site set on the authenticator, else its issuer mapped to a site, else the issuer.
    static func source(urls: [String], issuer: String) -> AuthSource? {
        if let domain = AuthSource.domains(ofSites: urls).first { return .domain(domain) }
        let trimmed = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return IssuerDomains.domain(for: trimmed).map(AuthSource.domain) ?? .issuer(trimmed)
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let fields: [String?] = switch self {
        case .secret(let s): [s.payload.name, s.payload.username] + (s.payload.urls ?? []).map(Optional.some)
        case .otp(let o): [o.payload.issuer, o.payload.account]
        case .shared(let s): [s.batch.issuer, s.batch.account, s.ownerName]
        case .code(let c): [c.sender, c.domain]
        }
        return (fields.compactMap { $0 } + [source?.name ?? ""]).contains { $0.localizedStandardContains(query) }
    }
}

struct AuthView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    struct Section: Identifiable {
        var id: String
        var title: String
        var source: AuthSource?
        var items: [AuthEntry]
    }

    private func sections(now: Date) -> [Section] {
        let vault = model.vault.state
        let liveCodes = model.codes.codes.filter { $0.isLive(at: now) }
        let query = search.trimmingCharacters(in: .whitespaces)
        let entries: [AuthEntry] = (vault.secrets.map(AuthEntry.secret) + vault.otps.map(AuthEntry.otp)
            + vault.shared.filter { $0.batch.code(at: now) != nil }.map(AuthEntry.shared)
            + liveCodes.filter { $0.domain != nil }.map(AuthEntry.code))
            .filter { $0.matches(query) }
        // Sites with a fresh code from a message first, then the ones used last.
        var lastUsed = RecentSites.lastUsed()
        for code in liveCodes {
            guard let domain = code.domain else { continue }
            let key = AuthSource.domain(domain).key
            lastUsed[key] = max(lastUsed[key] ?? .distantPast, code.receivedAt.addingTimeInterval(24 * 3600))
        }
        var sections = AuthSourceGrouping.group(entries, source: \.source, title: \.title, lastUsed: lastUsed)
            .map { Section(id: $0.source?.key ?? "none", title: $0.title, source: $0.source, items: $0.items) }
        // Codes nobody could place: on top, so they're found while they're fresh.
        let unplaced = liveCodes.filter { $0.domain == nil }.map(AuthEntry.code).filter { $0.matches(query) }
        if !unplaced.isEmpty { sections.insert(Section(id: "messages", title: "From messages", items: unplaced), at: 0) }
        return sections
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let sections = sections(now: context.date)
                List {
                    ForEach(sections) { section in
                        SwiftUI.Section(section.title) {
                            ForEach(section.items) { entry in
                                AuthRow(entry: entry, source: section.source, now: context.date)
                            }
                        }
                    }
                }
                .overlay {
                    if sections.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "Nothing in Auth yet" : "No results", systemImage: "key",
                                               description: Text(search.isEmpty
                                                                 ? "Passwords and authenticators from your Mac show up here, and codes from text messages once SMS codes are set up (Settings)."
                                                                 : ""))
                    }
                }
            }
            .searchable(text: $search)
            .refreshable { await model.syncNow() }
            .navigationTitle("Auth")
        }
    }
}

struct AuthRow: View {
    @Environment(AppModel.self) private var model
    let entry: AuthEntry
    let source: AuthSource?
    let now: Date
    @State private var revealed = false
    @State private var assigning = false
    @State private var assignSite = ""

    var body: some View {
        switch entry {
        case .secret(let secret): secretRow(secret)
        case .otp(let otp): otpRow(otp)
        case .shared(let shared): sharedRow(shared)
        case .code(let code): codeRow(code)
        }
    }

    private func secretRow(_ secret: MobileSecret) -> some View {
        Button {
            Task { await copyPassword(secret) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(secret.payload.username ?? secret.payload.name).foregroundStyle(.primary)
                Text(revealed ? secret.payload.value : String(repeating: "•", count: 10))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(revealed ? nil : 1)
                    .textSelection(.enabled)
            }
        }
        .contextMenu {
            Button("Copy Password", systemImage: "key") { Task { await copyPassword(secret) } }
            if let username = secret.payload.username {
                Button("Copy Username", systemImage: "person") {
                    UIPasteboard.general.string = username
                    RecentSites.record(source?.domain)
                }
            }
            Button(revealed ? "Hide" : "Show", systemImage: revealed ? "eye.slash" : "eye") {
                Task {
                    if revealed {
                        revealed = false
                    } else if await model.authenticate(reason: "Show this password") {
                        revealed = true
                    }
                }
            }
            if let site = secret.payload.urls?.first, let url = URL(string: site.contains("://") ? site : "https://" + site) {
                Link(destination: url) { Label("Open \(source?.name ?? site)", systemImage: "safari") }
            }
        }
    }

    private func copyPassword(_ secret: MobileSecret) async {
        guard await model.authenticate(reason: "Copy this password") else { return }
        model.copySensitive(secret.payload.value, label: "Password copied", source: source?.domain)
    }

    private func otpRow(_ otp: MobileOTP) -> some View {
        let p = otp.payload
        let code = Base32.decode(p.secret).flatMap {
            TOTP.code(key: $0, time: now, algorithm: OTPAlgorithm(parsing: p.algorithm) ?? .sha1, digits: p.digits, period: p.period)
        }
        return codeButton(title: entry.title, subtitle: p.issuer, code: code, period: p.period)
    }

    private func sharedRow(_ shared: MobileSharedCodes) -> some View {
        codeButton(title: entry.title, subtitle: "Shared by \(shared.ownerName)", code: shared.batch.code(at: now),
                   period: shared.batch.period)
    }

    private func codeButton(title: String, subtitle: String, code: String?, period: Int) -> some View {
        Button {
            if let code { model.copySensitive(code, label: "Code copied", source: source?.domain) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(code.map(TOTP.grouped) ?? "—")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                Gauge(value: TOTP.fractionRemaining(at: now, period: period)) { EmptyView() }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .scaleEffect(0.45)
                    .frame(width: 24, height: 24)
            }
        }
    }

    private func codeRow(_ code: SignInCode) -> some View {
        Button {
            model.copySensitive(code.code, label: "Code copied", source: code.domain)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(code.sender.map { "Message from \($0)" } ?? "Text message").foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Text(code.receivedAt, format: .relative(presentation: .named))
                        if code.reason?.isGuess == true, let domain = code.domain { Text("· guessed \(domain)") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(TOTP.grouped(code.code))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .contextMenu {
            Button(code.domain == nil ? "Assign to Site…" : "Change Site…", systemImage: "globe") {
                assignSite = code.domain ?? ""
                assigning = true
            }
            Button("Remove", systemImage: "trash", role: .destructive) { model.codes.remove(code.id) }
        }
        .alert("Which site is this code for?", isPresented: $assigning) {
            TextField("example.com", text: $assignSite)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Save") { model.codes.assign(code.id, to: assignSite) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(code.sender.map { "Codes from \($0) will go there from now on." } ?? "")
        }
    }
}
