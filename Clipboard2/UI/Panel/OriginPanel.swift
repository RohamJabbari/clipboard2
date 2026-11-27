import AppKit
import Observation
import UniformTypeIdentifiers

// The origin page (docs/features/auth-autofill.md → Origins): selecting a source heading in Auth,
// or ⌘K → Edit Site… on an entry, opens everything for that site in the right pane, inline.

/// The page's drafts and inline confirms. Edits to the name, sites and icon wait for Save;
/// notes, documents and entries change at once.
@Observable
final class OriginPageState {
    /// What the page is for; nil while it's a new site nobody saved yet.
    var key: AuthGroupKey?
    var name: String
    /// One row per site; an empty last row is where the next one is typed.
    var domains: [String]
    var icon: OriginIcon
    var emojiDraft: String
    var newNote = ""
    var editingNoteID: String?
    var noteDraft = ""
    var confirmingDelete = false
    var confirmingDocumentID: String?
    var confirmingEntryID: String?
    /// The site picked in Merge Into, waiting for its inline confirm.
    var mergeTarget: AuthGroupKey?
    var error: String?
    /// What the saved values were, to tell whether Save has anything to do.
    private(set) var savedName: String
    private(set) var savedDomains: [String]
    private(set) var savedIcon: OriginIcon

    init(key: AuthGroupKey?, origin: AuthOrigin?, fallbackName: String = "", fallbackDomains: [String] = []) {
        self.key = key
        let name = origin?.name ?? fallbackName
        let domains = origin?.domains ?? fallbackDomains
        let icon = origin?.icon ?? .favicon(nil)
        self.name = name
        self.domains = domains.isEmpty ? [""] : domains
        self.icon = icon
        if case .emoji(let text) = icon { emojiDraft = text } else { emojiDraft = "" }
        savedName = name
        savedDomains = SecretExtras.cleanURLs(domains)
        savedIcon = icon
    }

    var isNew: Bool { key == nil }
    var cleanDomains: [String] { SecretExtras.cleanURLs(domains) }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var hasUnsavedDetails: Bool {
        trimmedName != savedName.trimmingCharacters(in: .whitespacesAndNewlines) || cleanDomains != savedDomains || icon != savedIcon
    }

    var canSaveDetails: Bool { !trimmedName.isEmpty || !cleanDomains.isEmpty }

    func markSaved(_ origin: AuthOrigin) {
        savedName = origin.name
        savedDomains = origin.domains
        savedIcon = origin.icon
        name = origin.name
        domains = origin.domains.isEmpty ? [""] : origin.domains
        icon = origin.icon
    }

    func addDomainRow() {
        if domains.last?.trimmingCharacters(in: .whitespaces).isEmpty != true { domains.append("") }
    }

    func removeDomain(at index: Int) {
        guard domains.indices.contains(index) else { return }
        domains.remove(at: index)
        if domains.isEmpty { domains = [""] }
    }
}

/// A place an entry can be moved to, or a site merged into.
struct OriginTarget: Identifiable, Hashable {
    var key: AuthGroupKey
    var title: String
    var id: String { key.usageKey.isEmpty ? "none" : key.usageKey }
}

extension PanelViewModel {
    // MARK: Opening

    var originDirectory: OriginDirectory { env.origins.directory }

    /// The group an Auth row is listed under.
    func originKey(of entry: PanelEntry) -> AuthGroupKey? {
        let directory = originDirectory
        switch entry {
        case .secret(let ref): return directory.key(of: ref)
        case .authenticator(let item): return directory.key(of: item)
        case .emailCode(let code, _): return directory.key(ofCodeFrom: code.source)
        default: return nil
        }
    }

    /// The page of a group: a heading clicked, ⌘K → Edit Site…, or a site with nothing in it.
    func openOriginPage(_ key: AuthGroupKey) {
        let origin = env.origins.origin(withID: key.originID)
        let fallback: (String, [String]) = switch key {
        case .origin: ("", [])
        case .source(.domain(let domain)): (domain, [domain])
        case .source(.issuer(let issuer)): (issuer, [])
        case .none: ("", [])
        }
        if mode != .browse && mode != .originPage { resetMode() }
        originPage = OriginPageState(key: key, origin: origin, fallbackName: fallback.0, fallbackDomains: fallback.1)
        selectedCardID = nil
        presentOriginPage()
    }

    func openOriginPage(for entry: PanelEntry) {
        guard let key = originKey(of: entry) else { return }
        selectedID = entry.id
        openOriginPage(key)
    }

    /// + → New Site…: a page with nothing saved yet.
    func beginNewOrigin() {
        if mode != .browse && mode != .originPage { resetMode() }
        originPage = OriginPageState(key: nil, origin: nil)
        selectedCardID = nil
        presentOriginPage()
    }

    func closeOriginPage() {
        siteReturn = nil
        originPage = nil
        resetMode()
    }

    /// The page's title and icon.
    func originPageHeading(_ page: OriginPageState) -> AuthSourceHeading {
        guard let key = page.key else { return AuthSourceHeading(source: nil) }
        switch key {
        case .origin(let id):
            let origin = env.origins.origin(withID: id)
            return AuthSourceHeading(source: origin?.faviconDomain().map(AuthSource.domain), origin: origin)
        case .source(let source): return AuthSourceHeading(source: source)
        case .none: return AuthSourceHeading(source: nil)
        }
    }

    /// What the page lists: the group's passwords, secrets and authenticators.
    func originPageEntries(_ key: AuthGroupKey?) -> (secrets: [SecretRef], authenticators: [AuthenticatorItem]) {
        guard let key else { return ([], []) }
        let directory = originDirectory
        let (secrets, authenticators) = authList()
        return (secrets.filter { directory.key(of: $0) == key }
                    .sorted { ($0.username ?? $0.name).localizedStandardCompare($1.username ?? $1.name) == .orderedAscending },
                authenticators.filter { directory.key(of: $0) == key }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }

    /// Every other group and site an entry can go to (or a site be merged into), by title.
    func originTargets(excluding key: AuthGroupKey?) -> [OriginTarget] {
        var targets: [OriginTarget] = []
        var seen = Set<AuthGroupKey>()
        let directory = originDirectory
        for origin in directory.origins where seen.insert(.origin(origin.id)).inserted {
            targets.append(OriginTarget(key: .origin(origin.id), title: origin.title))
        }
        let (secrets, authenticators) = authList()
        let keys = secrets.map { directory.key(of: $0) } + authenticators.map { directory.key(of: $0) }
        for groupKey in keys {
            guard case .source(let source) = groupKey, seen.insert(groupKey).inserted else { continue }
            targets.append(OriginTarget(key: groupKey, title: source.name))
        }
        return targets.filter { $0.key != key }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: The site itself

    /// The origin behind a group, made on first edit: a site's group becomes an origin claiming
    /// that domain; an issuer's an origin of that name, with its entries filed under it.
    @discardableResult
    func materializeOrigin(for key: AuthGroupKey) -> AuthOrigin? {
        switch key {
        case .origin(let id):
            return env.origins.origin(withID: id)
        case .source(.domain(let domain)):
            return env.origins.create(name: domain, domains: [domain])
        case .source(.issuer(let issuer)):
            let members = originPageEntries(key)
            guard let origin = env.origins.create(name: issuer) else { return nil }
            for ref in members.secrets { file(.secret(ref), under: origin.id) }
            for item in members.authenticators { file(.authenticator(item), under: origin.id) }
            return env.origins.origin(withID: origin.id)
        case .none:
            return nil
        }
    }

    /// The page's origin, made if it's a group without one yet; the page follows it.
    @discardableResult
    func pageOrigin() -> AuthOrigin? {
        guard let page = originPage else { return nil }
        if page.isNew {
            guard page.canSaveDetails else {
                page.error = "Enter a name or a website first."
                return nil
            }
            guard let created = env.origins.create(name: page.trimmedName, domains: page.cleanDomains, icon: page.icon) else {
                page.error = "Couldn't save to the Keychain."
                return nil
            }
            page.key = .origin(created.id)
            page.markSaved(created)
            refresh()
            return created
        }
        guard let key = page.key else { return nil }
        if case .none = key {
            page.error = "“No website” isn't a site. Move entries to a site instead."
            return nil
        }
        guard let origin = materializeOrigin(for: key) else {
            page.error = "Couldn't save to the Keychain."
            return nil
        }
        if page.key != .origin(origin.id) {
            page.key = .origin(origin.id)
            if siteReturn != nil { siteReturn = .origin(origin.id) }
        }
        return origin
    }

    /// Save on the page: name, sites and icon.
    func saveOriginDetails() {
        guard let page = originPage else { return }
        page.error = nil
        guard page.canSaveDetails else {
            page.error = "Enter a name or a website."
            return
        }
        // A domain another site claims would be claimed twice; merging is the way to join them.
        let directory = originDirectory
        for domain in AuthSource.domains(ofSites: page.cleanDomains) {
            if let other = directory.origin(claiming: domain), page.key != .origin(other.id) {
                page.error = "\(domain) belongs to “\(other.title)”. Use Merge Into to join the two."
                return
            }
        }
        if page.isNew {
            guard pageOrigin() != nil else { return }
            showNotice("Saved “\(page.trimmedName.isEmpty ? page.cleanDomains.first ?? "Site" : page.trimmedName)”")
            return
        }
        guard var origin = pageOrigin() else { return }
        origin.name = page.trimmedName
        origin.domains = page.cleanDomains
        origin.icon = page.icon
        guard env.origins.save(origin) else {
            page.error = "Couldn't save to the Keychain."
            return
        }
        if let saved = env.origins.origin(withID: origin.id) { page.markSaved(saved) }
        refresh()
        showNotice("Saved “\(origin.title)”")
    }

    func setOriginIcon(_ icon: OriginIcon) {
        originPage?.icon = icon
    }

    /// Delete Site (after its inline confirm): the origin, its notes and documents go; its
    /// entries go back to automatic grouping, unchanged.
    func deleteOrigin() {
        guard let page = originPage, let id = page.key?.originID, let origin = env.origins.origin(withID: id) else { return }
        let members = originPageEntries(page.key)
        for ref in members.secrets where ref.originID == id { file(.secret(ref), under: nil) }
        for item in members.authenticators where item.originID == id { file(.authenticator(item), under: nil) }
        env.origins.delete(id: id)
        closeOriginPage()
        refresh(resetSelection: true)
        showNotice("Deleted “\(origin.title)” · its entries are grouped by their sites again")
    }

    // MARK: Notes

    func addOriginNote() {
        guard let page = originPage else { return }
        let text = page.newNote
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let origin = pageOrigin() else { return }
        guard env.origins.addNote(text, to: origin.id) != nil else {
            page.error = "Couldn't save the note."
            return
        }
        page.newNote = ""
        refresh()
    }

    func beginEditNote(_ note: OriginNote) {
        originPage?.editingNoteID = note.id
        originPage?.noteDraft = note.text
    }

    func saveEditedNote() {
        guard let page = originPage, let noteID = page.editingNoteID, let id = page.key?.originID else { return }
        env.origins.updateNote(noteID, text: page.noteDraft, in: id)
        page.editingNoteID = nil
        page.noteDraft = ""
    }

    func deleteOriginNote(_ note: OriginNote) {
        guard let id = originPage?.key?.originID else { return }
        env.origins.deleteNote(note.id, in: id)
        if originPage?.editingNoteID == note.id { originPage?.editingNoteID = nil }
    }

    // MARK: Documents

    /// Add Files…: the system file chooser (the only window it opens), then each file is
    /// encrypted into the vault.
    func chooseOriginDocuments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Files are encrypted and kept with this site."
        isChoosingFolder = true
        NSApp.activate()
        let response = panel.runModal()
        isChoosingFolder = false
        onRefocus()
        guard response == .OK else { return }
        addOriginDocuments(panel.urls)
    }

    /// Dropped or chosen files. Folders are skipped.
    @discardableResult
    func addOriginDocuments(_ urls: [URL]) -> Int {
        guard let page = originPage, !urls.isEmpty, let origin = pageOrigin() else { return 0 }
        var added = 0
        var problems: [String] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                problems.append("\(url.lastPathComponent) is a folder")
                continue
            }
            switch env.origins.addDocument(at: url, to: origin.id) {
            case .success: added += 1
            case .failure(.tooLarge): problems.append("\(url.lastPathComponent) is larger than 95 MB")
            case .failure(.tooMany): problems.append("a site holds at most \(OriginStore.maxDocuments) documents")
            case .failure(.unreadable): problems.append("\(url.lastPathComponent) can't be read")
            case .failure(.notSaved): problems.append("\(url.lastPathComponent) couldn't be saved")
            }
        }
        page.error = problems.isEmpty ? nil : "Not added: " + problems.joined(separator: "; ") + "."
        if added > 0 { showNotice(added == 1 ? "Added 1 document" : "Added \(added) documents") }
        return added
    }

    /// A decrypted copy in the app's temporary folder, for Open, Quick Look and Paste.
    private func exportedDocument(_ document: OriginDocument) -> URL? {
        guard let data = env.origins.documentData(document.id) else {
            originPage?.error = "“\(document.name)” isn't on this Mac yet."
            return nil
        }
        return OriginDocumentFiles.export(data, document: document)
    }

    func openOriginDocument(_ document: OriginDocument) {
        guard let url = exportedDocument(document) else { return }
        NSWorkspace.shared.open(url)
    }

    func quickLookOriginDocument(_ document: OriginDocument) {
        guard let url = exportedDocument(document) else { return }
        quickLookOverride = [url]
        if isQuickLookOpen() { onQuickLookItemsChanged() } else { onQuickLook(true) }
    }

    /// Pastes the file into the app the panel was opened over, like a file clip.
    func pasteOriginDocument(_ document: OriginDocument) {
        guard let url = exportedDocument(document) else { return }
        let target = targetApp
        onClose()
        env.paste.paste(fileURLs: [url], into: target)
    }

    func removeOriginDocument(_ document: OriginDocument) {
        guard let page = originPage, let id = page.key?.originID else { return }
        page.confirmingDocumentID = nil
        env.origins.removeDocument(document.id, from: id)
        showNotice("Removed “\(document.name)”")
    }

    // MARK: Entries

    /// Whether this Mac may change an entry (your own, or a group secret you wrote).
    func canRefile(_ entry: PanelEntry) -> Bool {
        switch entry {
        case .secret(let ref): env.sync.canChange(itemID: ref.id, spaceID: ref.spaceID)
        case .authenticator(.owned): true
        default: false
        }
    }

    /// Files an entry under an origin (nil: back to automatic grouping). Your own entries carry
    /// the reference; ones you can't change (shared authenticators, others' group secrets) are
    /// listed in the origin instead.
    func file(_ entry: PanelEntry, under originID: String?) {
        let pin: String?
        switch entry {
        case .secret(let ref):
            if env.sync.canChange(itemID: ref.id, spaceID: ref.spaceID) {
                env.secrets.setOrigin(originID, for: [ref])
                pin = nil
                env.origins.pin(AuthEntryKey.of(ref), to: nil)
            } else {
                pin = AuthEntryKey.of(ref)
            }
        case .authenticator(let item):
            if case .owned(let authenticator) = item {
                env.authenticators.setOrigin(originID, id: authenticator.id)
                pin = nil
                env.origins.pin(AuthEntryKey.of(item), to: nil)
            } else {
                pin = AuthEntryKey.of(item)
            }
        default:
            return
        }
        if let pin { env.origins.pin(pin, to: originID) }
    }

    /// Move to ‹site› on the page (or the row's menu): makes the target an origin if it's a
    /// group without one, then files the entry there.
    func moveEntry(_ entry: PanelEntry, to target: AuthGroupKey) {
        if case .none = target {
            file(entry, under: nil)
        } else {
            guard let origin = materializeOrigin(for: target) else { return }
            file(entry, under: origin.id)
        }
        refresh()
        let title: String = switch target {
        case .origin(let id): env.origins.origin(withID: id)?.title ?? "the site"
        case .source(let source): source.name
        case .none: "its own sites"
        }
        if let page = originPage, let key = page.key, case .origin(let id) = key, env.origins.origin(withID: id) == nil {
            page.key = target
        }
        showNotice("Moved to \(title)")
    }

    /// Merge Into (after its inline confirm): everything on this page moves to `target`, and this
    /// site goes. The page then shows `target`.
    func mergeOrigin(into target: AuthGroupKey) {
        guard let page = originPage, let key = page.key else { return }
        page.mergeTarget = nil
        let members = originPageEntries(key)
        let draft = page.cleanDomains
        guard let destination = materializeOrigin(for: target) else {
            page.error = "Couldn't save to the Keychain."
            return
        }
        // Entries first: those filed by reference or listed here go to the destination.
        for ref in members.secrets { file(.secret(ref), under: destination.id) }
        for item in members.authenticators { file(.authenticator(item), under: destination.id) }
        if let sourceID = key.originID {
            guard env.origins.merge(sourceID, into: destination.id) != nil else {
                page.error = "Couldn't merge: together they'd hold more than \(OriginStore.maxDocuments) documents, or a document isn't on this Mac yet."
                return
            }
        } else if var merged = env.origins.origin(withID: destination.id) {
            // A group without an origin brings its domain.
            merged.domains += draft
            env.origins.save(merged)
        }
        let title = env.origins.origin(withID: destination.id)?.title ?? "the site"
        refresh()
        openOriginPage(.origin(destination.id))
        showNotice("Merged into \(title)")
    }

    // MARK: Adding from the page

    /// New Login… / New Secret… with the site filled in; the form comes back to the page.
    func beginNewEntry(_ kind: EditSecretState.Kind, onPage page: OriginPageState) {
        guard let key = page.key else {
            page.error = "Save the site first."
            return
        }
        let form = EditSecretState(new: kind)
        let site = sitePrefill(for: key)
        if kind == .password, let site { form.sites = [site] }
        form.siteKey = key
        siteReturn = key
        presentEditSecret(form)
    }

    func beginNewAuthenticator(onPage page: OriginPageState) {
        guard let key = page.key else {
            page.error = "Save the site first."
            return
        }
        let form = AuthenticatorFormState(purpose: .add(from: nil), showsTip: !hasSeenAuthenticatorTip)
        if let site = sitePrefill(for: key) { form.website = site }
        if case .source(.issuer(let issuer)) = key { form.issuer = issuer }
        if case .origin(let id) = key, let origin = env.origins.origin(withID: id), form.issuer.isEmpty {
            form.issuer = origin.title
        }
        form.siteKey = key
        siteReturn = key
        presentAuthenticatorForm(form)
    }

    func editEntry(_ entry: PanelEntry, onPage page: OriginPageState) {
        siteReturn = page.key
        switch entry {
        case .secret(let ref): beginEditSecret(ref)
        case .authenticator(.owned(let authenticator)): beginRename(authenticator)
        default: siteReturn = nil
        }
    }

    /// Delete on the page (after its inline confirm).
    func deleteEntry(_ entry: PanelEntry) {
        originPage?.confirmingEntryID = nil
        switch entry {
        case .secret(let ref):
            env.slots.remove(target: .secret(ref.id))
            env.secrets.delete(ref)
            showNotice("Deleted “\(ref.name)”")
        case .authenticator(.owned(let authenticator)):
            env.authenticators.delete(id: authenticator.id)
            env.sync.syncNow()
            showNotice("Deleted “\(AuthenticatorItem.owned(authenticator).title)”")
        default:
            return
        }
        refresh()
    }

    /// The site a new login gets: the origin's first, or the group's domain.
    private func sitePrefill(for key: AuthGroupKey) -> String? {
        switch key {
        case .origin(let id): env.origins.origin(withID: id)?.domains.first
        case .source(.domain(let domain)): domain
        default: nil
        }
    }

    /// After a form opened from the page saved something: file it under the page's site when
    /// it wouldn't land there by itself.
    func fileNewEntry(_ entry: PanelEntry, under key: AuthGroupKey?) {
        guard let key, originKey(of: entry) != key else { return }
        if case .none = key { return }
        guard let origin = materializeOrigin(for: key) else { return }
        file(entry, under: origin.id)
        if siteReturn == key { siteReturn = .origin(origin.id) }
    }

    // MARK: QR codes

    /// Scan QR on Screen: the screenshot crosshair, then the `otpauth://` link in what was picked.
    func scanQRCodeOnScreen() {
        guard let form = authenticatorForm else { return }
        let snapshot = env.paste.snapshot()
        isChoosingFolder = true
        Task {
            let image = await ScreenTextCapture.captureRegionToClipboard()
            env.paste.restore(snapshot)
            isChoosingFolder = false
            onRefocus()
            guard let image else { return }
            guard let link = OTPQRCode.link(in: image) else {
                form.error = "No authenticator QR code in that area."
                return
            }
            form.useLink(link)
        }
    }

    /// QR from Image…: an image file with the QR code.
    func chooseQRImage() {
        guard let form = authenticatorForm else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Read QR Code"
        isChoosingFolder = true
        NSApp.activate()
        let response = panel.runModal()
        isChoosingFolder = false
        onRefocus()
        guard response == .OK, let url = panel.url else { return }
        Task {
            guard let link = await OTPQRCode.link(at: url) else {
                form.error = "No authenticator QR code in that image."
                return
            }
            form.useLink(link)
        }
    }
}

extension AuthenticatorFormState {
    /// A pasted, scanned or read `otpauth://` link: its issuer, account and settings fill the
    /// form, and its secret is kept (never shown).
    func useLink(_ text: String) {
        switch OTPAuthURI.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case .success(let account):
            scanned = account
            if !account.issuer.isEmpty { issuer = account.issuer }
            if !account.account.isEmpty { self.account = account.account }
            algorithm = account.algorithm
            digits = account.digits
            period = account.period
            secret = ""
            error = nil
        case .failure(let problem):
            error = problem.localizedDescription
        }
    }
}
