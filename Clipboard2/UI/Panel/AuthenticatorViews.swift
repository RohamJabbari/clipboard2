import SwiftUI

/// Once a second while the panel is open; only the views that read `now` redraw.
@Observable
final class OTPClock {
    private(set) var now = Date.now
    @ObservationIgnored private var timer: Timer?

    func start() {
        now = .now
        guard timer == nil else { return }
        // Fires on the second boundary, so codes change when the second does.
        let next = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970) + 1)
        let timer = Timer(fire: next, interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = .now }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// What the row and preview say under the name.
enum AuthenticatorStatus {
    static func line(for item: AuthenticatorItem, shareCount: Int?, now: Date) -> (text: String, warning: Bool)? {
        switch item {
        case .owned:
            guard let shareCount, shareCount > 0 else { return nil }
            return ("Shared with \(shareCount)", false)
        case .shared(let shared):
            switch shared.status(at: now) {
            case .ok: return ("Shared by \(shared.ownerName)", false)
            case .runningOut(let until):
                return ("Codes until \(until.formatted(date: .omitted, time: .shortened))", true)
            case .empty: return ("No codes, \(shared.ownerName)'s devices have been offline", true)
            }
        }
    }
}

/// A small ring that empties as the code's time runs out; red for the last 5 seconds.
struct CountdownRing: View {
    let fraction: Double
    let secondsLeft: Int
    var isSelected = false
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().stroke(isSelected ? AnyShapeStyle(.white.opacity(0.3)) : AnyShapeStyle(.quaternary), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(secondsLeft) seconds left")
    }

    private var color: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white) }
        return secondsLeft <= 5 ? AnyShapeStyle(.red) : AnyShapeStyle(.tint)
    }
}

/// The live code and its ring. Reads the clock, so only this part redraws each second.
struct LiveCode: View {
    let item: AuthenticatorItem
    let clock: OTPClock
    var isSelected = false
    var fontSize: CGFloat = 17
    var ringSize: CGFloat = 16

    var body: some View {
        let now = clock.now
        let code = item.code(at: now)
        HStack(spacing: 8) {
            Text(code.map(TOTP.grouped) ?? String(repeating: "–", count: 3) + " " + String(repeating: "–", count: 3))
                .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : code == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .contentTransition(.numericText())
            if code != nil {
                CountdownRing(fraction: TOTP.fractionRemaining(at: now, period: item.period),
                              secondsLeft: TOTP.secondsRemaining(at: now, period: item.period),
                              isSelected: isSelected, size: ringSize)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(code.map { "Code \($0.map(String.init).joined(separator: " "))" } ?? "No code")
    }
}

/// An authenticator in the list: issuer, account (or who shares it), and the live code.
struct AuthenticatorRow: View {
    let item: AuthenticatorItem
    let isSelected: Bool
    var showsCheckmark = false
    var query = ""
    var shareCount: Int?
    let clock: OTPClock
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if showsCheckmark {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
            ContentBadge(kind: .authenticator, isSelected: isSelected)
            VStack(alignment: .leading, spacing: 2) {
                Text(SearchHighlight.text(item.title, query: query, onAccent: isSelected))
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                AuthenticatorSubtitle(item: item, shareCount: shareCount, clock: clock, isSelected: isSelected)
            }
            Spacer(minLength: 4)
            LiveCode(item: item, clock: clock, isSelected: isSelected)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor)
                      : hovering ? AnyShapeStyle(Color.primary.opacity(0.05)) : AnyShapeStyle(.clear))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Authenticator \(item.title)" + (item.subtitle.isEmpty ? "" : ", \(item.subtitle)"))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Double-click or press Return to paste the code")
    }
}

struct AuthenticatorSubtitle: View {
    let item: AuthenticatorItem
    let shareCount: Int?
    let clock: OTPClock
    var isSelected = false

    var body: some View {
        let status = AuthenticatorStatus.line(for: item, shareCount: shareCount, now: clock.now)
        HStack(spacing: 4) {
            if let status {
                Image(systemName: item.isOwned ? "person.2.fill" : status.warning ? "exclamationmark.circle.fill" : "person.crop.circle")
                    .imageScale(.small)
                Text(status.text)
                    .fontWeight(.semibold)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : status.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.purple))
                if !item.subtitle.isEmpty { Text("·") }
            }
            if !item.subtitle.isEmpty || status == nil {
                Text(item.subtitle.isEmpty ? "Authenticator" : item.subtitle)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
    }
}

/// "Add to Authenticator" for a copied link or QR code (its secret is never shown).
struct AuthenticatorSuggestionRow: View {
    let account: OTPAccount
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ContentBadge(kind: .authenticator, isSelected: isSelected)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add to Authenticator")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Text([account.issuer, account.account].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 4)
            Text("esc to dismiss")
                .font(.caption2)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.green.opacity(0.08)))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Press Return to add it")
    }
}

// MARK: - Preview

struct AuthenticatorPreview: View {
    let item: AuthenticatorItem
    let model: PanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ContentBadge(kind: .authenticator, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.title3.weight(.semibold)).lineLimit(2)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            LiveCode(item: item, clock: model.otpClock, fontSize: 34, ringSize: 26)
                .padding(.vertical, 4)
            AuthenticatorSubtitle(item: item, shareCount: model.shareCount(of: item), clock: model.otpClock)
            buttons
            if case .owned(let authenticator) = item {
                if model.pendingDeleteID == authenticator.id {
                    deleteConfirm(authenticator)
                } else if model.revealedSecretID == authenticator.id {
                    SecretReveal(authenticator: authenticator, onHide: model.hideSecret)
                }
            }
            Spacer(minLength: 0)
            Divider()
            details
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var buttons: some View {
        let actions = PanelAction.authenticatorActions(for: item, signedIn: model.env.sync.isSignedIn,
                                                       shareCount: model.shareCount(of: item))
        HStack {
            Button("Paste Code") { model.pasteCode(of: item) }
                .buttonStyle(.borderedProminent)
            Button("Copy Code") { model.copyCode(of: item) }
                .help("Not kept in history, and cleared from the clipboard after 30 seconds")
        }
        let more = actions.compactMap { action -> AuthenticatorAction? in
            if case .authenticator(let a) = action { a } else { nil }
        }
        if !more.isEmpty {
            FlowButtons(actions: more) { model.perform($0, on: item) }
        }
    }

    private func deleteConfirm(_ authenticator: Authenticator) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.shareCount(of: item).map { $0 > 0 } == true
                  ? "Delete for you and everyone it's shared with? Your other devices lose it too."
                  : "Delete it from all your devices? This can't be undone.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("Turn off two-factor sign-in on the site first, or keep another way to get codes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: model.cancelDelete)
                Button("Delete", role: .destructive) { model.confirmDelete(authenticator) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("Return")
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            switch item {
            case .owned(let authenticator):
                GridRow { Text("Owner").foregroundStyle(.secondary); Text("You") }
                GridRow {
                    Text("People").foregroundStyle(.secondary)
                    Text(peopleText(model.shareCount(of: item)))
                }
                GridRow {
                    Text("Codes").foregroundStyle(.secondary)
                    Text("\(authenticator.digits) digits · every \(authenticator.period) s · \(authenticator.algorithm.title)")
                }
                GridRow {
                    Text("Added").foregroundStyle(.secondary)
                    Text(authenticator.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
            case .shared(let shared):
                GridRow { Text("Owner").foregroundStyle(.secondary); Text(shared.ownerName) }
                GridRow {
                    Text("Codes until").foregroundStyle(.secondary)
                    Text(shared.batch.map { $0.until.formatted(date: .abbreviated, time: .shortened) } ?? "None yet")
                }
                GridRow {
                    Text("Secret").foregroundStyle(.secondary)
                    Text("Stays with \(shared.ownerName); you get codes only")
                }
            }
        }
        .font(.caption)
    }

    private func peopleText(_ count: Int?) -> String {
        switch count {
        case .none: "—"
        case .some(0): "Only you"
        case .some(1): "You and 1 person"
        case .some(let n): "You and \(n) people"
        }
    }
}

/// A row of the owner's actions under the preview's buttons.
private struct FlowButtons: View {
    let actions: [AuthenticatorAction]
    let perform: (AuthenticatorAction) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { buttons }
            VStack(alignment: .leading) { buttons }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var buttons: some View {
        ForEach(actions, id: \.self) { action in
            Button(role: action == .delete || action == .leave ? .destructive : nil) { perform(action) } label: {
                Label(action == .delete ? "Delete…" : action.title, systemImage: action.symbol)
            }
        }
    }
}

/// The base32 secret and a QR code for a phone app, after Touch ID.
private struct SecretReveal: View {
    let authenticator: Authenticator
    let onHide: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let image = OTPQRCode.image(for: OTPAuthURI.make(authenticator.otpAccount)) {
                Image(decorative: image, scale: 2)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 132, height: 132)
                    .padding(6)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("QR code to add it to a phone app")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Setup key").font(.caption).foregroundStyle(.secondary)
                Text(grouped(authenticator.secret))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Scan it with your phone's authenticator app to keep a copy there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Hide", action: onHide).controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func grouped(_ secret: String) -> String {
        stride(from: 0, to: secret.count, by: 4).map { start in
            let from = secret.index(secret.startIndex, offsetBy: start)
            let to = secret.index(from, offsetBy: min(4, secret.count - start))
            return String(secret[from..<to])
        }.joined(separator: " ")
    }
}

struct AuthenticatorSuggestionPreview: View {
    let account: OTPAccount
    let model: PanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ContentBadge(kind: .authenticator, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add to Authenticator").font(.title3.weight(.semibold))
                    Text([account.issuer, account.account].filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
            }
            Text("You copied an authenticator link or QR code. It isn't kept in your history; add it here to get its codes in Clipboard2.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Add…") { model.beginAddAuthenticator(from: account) }
                    .buttonStyle(.borderedProminent)
                Button("Dismiss", action: model.dismissSuggestion)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Forms

/// Issuer, Account (and the setup key when typed), Advanced, then Add. In the panel, never a dialog.
struct AuthenticatorFormView: View {
    @Bindable var form: AuthenticatorFormState
    let onSubmit: () -> Void
    @FocusState private var focus: Field?

    private enum Field { case issuer, secret }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(form.isRename ? "Rename Authenticator" : "New Authenticator", systemImage: "lock.shield")
                .font(.headline)
            if form.showsTip {
                Label("Keep your most important 2FA codes on your phone too. Clipboard2 is convenient, but it puts the password and the code in one place.",
                      systemImage: "iphone")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                TextField("Issuer", text: $form.issuer, prompt: Text("e.g. GitHub"))
                    .focused($focus, equals: .issuer)
                TextField("Account", text: $form.account, prompt: Text("e.g. me@example.com"))
                if form.asksForSecret {
                    TextField("Setup key", text: $form.secret, prompt: Text("Base32, e.g. JBSW Y3DP EHPK 3PXP"))
                        .font(.body.monospaced())
                        .focused($focus, equals: .secret)
                }
                if !form.isRename {
                    DisclosureGroup("Advanced", isExpanded: $form.showsAdvanced) {
                        Picker("Algorithm", selection: $form.algorithm) {
                            ForEach(OTPAlgorithm.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Digits", selection: $form.digits) {
                            ForEach(Array(TOTP.digitRange), id: \.self) { Text("\($0)").tag($0) }
                        }
                        Stepper("Every \(form.period) seconds", value: $form.period, in: 10...300, step: 5)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            if let error = form.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(form.isRename ? "Save" : "Add", action: onSubmit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear { focus = .issuer }
    }
}

/// Share… (pick a contact or group member), People… (with Remove) and Transfer Ownership….
struct AuthenticatorPeopleView: View {
    @Bindable var form: AuthenticatorPeopleState
    let model: PanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if form.isLoading {
                ProgressView().controlSize(.small)
            } else if form.rowCount == 0 {
                Text(emptyText).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        if form.purpose == .share {
                            ForEach(Array(form.candidates.enumerated()), id: \.element.id) { index, person in
                                row(index: index, name: person.name, detail: nil)
                            }
                        } else {
                            ForEach(Array(form.shares.enumerated()), id: \.element.id) { index, share in
                                row(index: index, name: share.name, detail: codesText(share), share: share)
                            }
                        }
                    }
                }
            }
            if let error = form.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .disabled(form.isBusy)
    }

    private func row(index: Int, name: String, detail: String?, share: AuthenticatorShare? = nil) -> some View {
        let selected = index == form.selection
        return HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                if let detail {
                    Text(detail).font(.caption)
                        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            Spacer()
            if form.purpose == .people, let share {
                Button("Remove", role: .destructive) { model.removeShare(share) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            form.selection = index
            if form.purpose != .people { model.submitPeople(at: index) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func codesText(_ share: AuthenticatorShare) -> String {
        guard let codesUntil = share.codesUntil else { return "No codes sent yet" }
        let until = Date(syncMillis: codesUntil)
        return until > .now ? "Codes until \(until.formatted(date: .omitted, time: .shortened))" : "No codes right now"
    }

    private var title: String {
        switch form.purpose {
        case .share: "Share “\(AuthenticatorItem.owned(form.authenticator).title)”"
        case .people: "People"
        case .transfer: "Transfer Ownership"
        }
    }

    private var symbol: String {
        switch form.purpose {
        case .share: "person.badge.plus"
        case .people: "person.2"
        case .transfer: "arrow.right.arrow.left"
        }
    }

    private var note: String {
        switch form.purpose {
        case .share: "They get codes for the next 24 hours, topped up by your devices. They never get the secret."
        case .people: "Removing someone stops new codes. Codes they already have keep working until they run out."
        case .transfer: "They'll get the secret and own it; you'll get codes like everyone else."
        }
    }

    private var emptyText: String {
        switch form.purpose {
        case .share: "Nobody to share with yet. Add a contact or join a group in Settings → Sync."
        case .people, .transfer: "It isn't shared with anyone. Share it first."
        }
    }
}
