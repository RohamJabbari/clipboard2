import AppKit
import Observation
import SwiftUI

nonisolated enum PanelFilter: String, CaseIterable, Identifiable, Sendable {
    // Raw values are stored settings: `labelled` stays the Saved chip's, `inbox` Contacts'.
    case copies, labelled, auth, inbox, groups
    var id: String { rawValue }

    var title: String {
        switch self {
        case .copies: "Copies"
        case .labelled: "Saved"
        case .auth: "Auth"
        case .inbox: "Contacts"
        case .groups: "Groups"
        }
    }

    var symbol: String {
        switch self {
        case .copies: "doc.on.doc"
        case .labelled: "bookmark"
        case .auth: "key"
        case .inbox: "person.crop.circle"
        case .groups: "person.2"
        }
    }

    /// Each chip searches only its own content, and says so.
    var searchPrompt: String {
        switch self {
        case .copies: "Search copies"
        case .labelled: "Search Saved"
        case .auth: "Search Auth"
        case .inbox: "Search contacts"
        case .groups: "Search group"
        }
    }

    /// A stored filter: one whose chip is gone (All and This App before 1.11; Text, Images,
    /// Files, Snippets and Secrets before 1.7) or anything unknown falls back to Copies.
    init(storedValue: String?) {
        self = storedValue.flatMap(PanelFilter.init(rawValue:)) ?? .copies
    }

    /// Copies · Saved · Auth, then Contacts (Inbox | People) and Groups whenever you're signed in.
    static let chips: [PanelFilter] = [.copies, .labelled, .auth]
    static func chips(showsContacts: Bool) -> [PanelFilter] { showsContacts ? chips + [.inbox, .groups] : chips }
}

/// A stop in the filter row for ⇥: a chip, one segment of a group's pill, or Contacts → People.
nonisolated enum FilterStop: Equatable, Sendable {
    case chip(PanelFilter)
    case group(String, saved: Bool)
    /// The Contacts pill's People segment (`chip(.inbox)` is its Inbox).
    case people
}

enum PanelEntry: Identifiable {
    case clip(ClipItem)
    case snippet(Snippet)
    case secret(SecretRef)
    /// A Saved folder row (Saved tab only).
    case folder(ClipFolder)
    /// An authenticator: yours, or one shared with you (codes only). Personal Saved, and search.
    case authenticator(AuthenticatorItem)
    /// "Add to Authenticator" for a copied link or QR code, at the top of All until added or dismissed.
    case authenticatorSuggestion(OTPAccount)
    /// A code from an email (Auth, phase 4): in "Email codes" at the top, and again under its
    /// source when that source is listed (`inSource`).
    case emailCode(EmailCode, inSource: Bool = false)

    var id: String {
        switch self {
        case .clip(let item): "c-" + item.id.uuidString
        case .snippet(let snippet): "s-" + snippet.id.uuidString
        case .secret(let ref): "k-" + ref.id
        case .folder(let folder): "f-" + folder.id.uuidString
        case .authenticator(let item): "a-" + item.id
        case .authenticatorSuggestion: "a-suggestion"
        case .emailCode(let code, let inSource): (inSource ? "es-" : "e-") + code.id
        }
    }

    var authenticator: AuthenticatorItem? {
        if case .authenticator(let item) = self { return item }
        return nil
    }

    var isSuggestion: Bool {
        if case .authenticatorSuggestion = self { return true }
        return false
    }

    var clip: ClipItem? {
        if case .clip(let item) = self { return item }
        return nil
    }

    var folder: ClipFolder? {
        if case .folder(let folder) = self { return folder }
        return nil
    }

    var secret: SecretRef? {
        if case .secret(let ref) = self { return ref }
        return nil
    }

    var snippet: Snippet? {
        if case .snippet(let snippet) = self { return snippet }
        return nil
    }

    /// Where it sorts in Saved, newest first: when a clip was saved or last copied (the later),
    /// a secret's creation, a snippet's last edit.
    var savedDate: Date {
        switch self {
        case .clip(let item): max(item.pinnedAt ?? .distantPast, item.lastCopiedAt)
        case .snippet(let snippet): snippet.updatedAt
        case .secret(let ref): ref.createdAt ?? .distantPast
        case .folder(let folder): folder.createdAt
        case .authenticator(let item): item.createdAt
        case .authenticatorSuggestion: .now
        case .emailCode(let code, _): code.receivedAt
        }
    }

    /// Nil for folders and authenticators, which can't be put on a quick slot.
    var slotTarget: SlotTarget? {
        switch self {
        case .clip(let item): .clip(item.id)
        case .snippet(let snippet): .snippet(snippet.id)
        case .secret(let ref): .secret(ref.id)
        case .folder, .authenticator, .authenticatorSuggestion, .emailCode: nil
        }
    }
}

enum PanelMode: Equatable {
    case browse
    case actions
    case snippetForm
    case saveSecret
    case label
    case editSecret
    case shareToGroup
    case ai
    /// Naming a folder: renaming one, or a new one (which may take the selection with it).
    case folderName
    /// Adding an authenticator (from a link, a QR code or by hand), or renaming one.
    case authenticatorForm
    /// Share…, People… or Transfer Ownership… for an authenticator you own.
    case authenticatorPeople
    /// The Folder row's picker (⌘⇧M).
    case folderPicker
    /// Add Items in the Saved header, or Send… on a contact (`AddItemsState.contact`).
    case addItems
    /// Send to Contact…: pick one or more contacts for the selection.
    case contactPicker
    /// Add Contact in Contacts → People: a username or a code.
    case addContact
    /// Save… / Edit Saved…: label and one destination, yours or a group's.
    case save
}

enum PanelAction: Identifiable, Hashable {
    case paste
    case pastePlain
    case copy
    case quickLook
    case transform(Transform)
    case ai(AIAction)
    case saveAsSecret
    case setLabel
    /// Save… (Edit Saved… once saved): the label and where it's kept, in the right pane.
    case save
    case shareToGroup
    case sendToDevice(DeviceTarget)
    case sendToContact(SyncContact)
    /// Send to Contact…: the inline contact picker.
    case chooseContact
    case setUpAI
    case clearSlot(Int)
    case removeFromLabelled
    case addToSaved
    /// A personal copy, saved at the root of Saved (a group item you can't change).
    case saveCopy
    /// Into a folder of the items' space; a personal folder for group items saves copies.
    case moveToFolder(ClipFolder)
    /// A new folder in the items' space.
    case moveToNewFolder
    /// A new personal folder, with personal copies of the (group) items.
    case copyToNewFolder
    case removeFromFolder
    case openFolder
    case renameFolder
    case deleteFolder
    /// The selected folder (with everything in it) into another folder of its space.
    case moveFolder(ClipFolder)
    case moveFolderToTop
    case newSubfolder
    case saveToFolder
    case saveToChosenFolder
    case delete
    /// Rename, Share…, People…, Transfer, Show Secret, Delete or Leave on an authenticator.
    case authenticator(AuthenticatorAction)

    var id: String {
        switch self {
        case .paste: "paste"
        case .pastePlain: "pastePlain"
        case .copy: "copy"
        case .quickLook: "quickLook"
        case .transform(let t): "transform-" + t.rawValue
        case .ai(let a): "ai-" + a.id
        case .saveAsSecret: "saveAsSecret"
        case .setLabel: "setLabel"
        case .save: "save"
        case .shareToGroup: "shareToGroup"
        case .sendToDevice(let device): "sendToDevice-" + device.id
        case .sendToContact(let contact): "sendToContact-" + contact.id
        case .chooseContact: "chooseContact"
        case .setUpAI: "setUpAI"
        case .clearSlot(let n): "clearSlot-\(n)"
        case .removeFromLabelled: "removeFromLabelled"
        case .addToSaved: "addToSaved"
        case .saveCopy: "saveCopy"
        case .moveToFolder(let folder): "moveToFolder-" + folder.id.uuidString
        case .moveToNewFolder: "moveToNewFolder"
        case .copyToNewFolder: "copyToNewFolder"
        case .removeFromFolder: "removeFromFolder"
        case .openFolder: "openFolder"
        case .renameFolder: "renameFolder"
        case .deleteFolder: "deleteFolder"
        case .moveFolder(let folder): "moveFolder-" + folder.id.uuidString
        case .moveFolderToTop: "moveFolderToTop"
        case .newSubfolder: "newSubfolder"
        case .saveToFolder: "saveToFolder"
        case .saveToChosenFolder: "saveToChosenFolder"
        case .delete: "delete"
        case .authenticator(let action): "authenticator-" + action.rawValue
        }
    }

    func section(aiName: String) -> String {
        switch self {
        case .paste, .pastePlain, .copy, .quickLook: "Paste"
        case .transform: "Transform & Paste"
        case .ai, .setUpAI: "Ask \(aiName)"
        case .sendToDevice, .sendToContact, .chooseContact: "Send"
        case .saveToFolder, .saveToChosenFolder: "Save"
        case .addToSaved, .saveCopy, .moveToFolder, .moveToNewFolder, .copyToNewFolder, .removeFromFolder,
             .removeFromLabelled: "Saved"
        case .openFolder, .renameFolder, .deleteFolder, .moveFolder, .moveFolderToTop, .newSubfolder: "Folder"
        case .save: "Saved"
        case .saveAsSecret, .setLabel, .shareToGroup, .clearSlot, .delete: "Item"
        case .authenticator: "Authenticator"
        }
    }

    /// `folderName` is the save folder's name ("Save to Downloads").
    func title(folderName: String) -> String {
        switch self {
        case .paste: "Paste"
        case .pastePlain: "Paste as Plain Text"
        case .copy: "Copy to Clipboard"
        case .quickLook: "Quick Look"
        case .transform(let t): t.title
        case .ai(.instruction(let text)): "Ask: “\(text)”"
        case .ai(let a): a.title
        case .saveAsSecret: "Save as Secret…"
        case .setLabel: "Label…"
        case .save: "Save…"
        case .shareToGroup: "Share to Group…"
        case .sendToDevice(let device): "Send to \(device.name)"
        case .sendToContact(let contact): "Send to \(contact.name)"
        case .chooseContact: "Send to Contact…"
        case .setUpAI: "Set Up AI…"
        case .clearSlot(let n): "Remove from Quick Slot ⌘\(n)"
        case .removeFromLabelled: "Remove from Saved"
        case .addToSaved: "Add to Saved"
        case .saveCopy: "Save a Copy"
        case .moveToFolder(let folder): "Move to “\(folder.name)”"
        case .moveToNewFolder: "Move to New Folder…"
        case .copyToNewFolder: "Save a Copy to New Folder…"
        case .removeFromFolder: "Move to Top Level"
        case .openFolder: "Open"
        case .renameFolder: "Rename…"
        case .deleteFolder: "Delete Folder"
        case .moveFolder(let folder): "Move to “\(folder.name)”"
        case .moveFolderToTop: "Move to Top Level"
        case .newSubfolder: "New Folder Inside…"
        case .saveToFolder: "Save to \(folderName)"
        case .saveToChosenFolder: "Save to…"
        case .delete: "Delete"
        case .authenticator(let action): action.title
        }
    }

    var symbol: String {
        switch self {
        case .paste: "doc.on.clipboard"
        case .pastePlain: "doc.plaintext"
        case .copy: "doc.on.doc"
        case .quickLook: "eye"
        case .transform(let t): t.symbol
        case .ai(let a): a.symbol
        case .saveAsSecret: "key"
        case .setLabel: "tag"
        case .save: "bookmark"
        case .shareToGroup: "person.2"
        case .sendToDevice: "laptopcomputer.and.arrow.down"
        case .sendToContact, .chooseContact: "paperplane"
        case .setUpAI: "sparkles"
        case .clearSlot: "number.square"
        case .removeFromLabelled: "bookmark.slash"
        case .addToSaved: "bookmark"
        case .saveCopy: "bookmark.square"
        case .moveToFolder: "folder"
        case .moveToNewFolder: "folder.badge.plus"
        case .copyToNewFolder: "folder.badge.plus"
        case .removeFromFolder: "folder.badge.minus"
        case .openFolder: "folder"
        case .renameFolder: "pencil"
        case .deleteFolder: "trash"
        case .moveFolder: "folder"
        case .moveFolderToTop: "arrow.up.to.line"
        case .newSubfolder: "folder.badge.plus"
        case .saveToFolder: "square.and.arrow.down"
        case .saveToChosenFolder: "folder"
        case .delete: "trash"
        case .authenticator(let action): action.symbol
        }
    }

    /// The keyboard shortcut shown next to the action in the ⌘K list.
    var shortcutHint: String? {
        switch self {
        case .setLabel: "⌘L"
        case .save: "⌘S"
        case .quickLook: "⌘Y"
        default: nil
        }
    }

    /// What the ⌘K menu offers on an authenticator. Owner-only actions are left out of ones shared
    /// with you (the server would refuse them), and sharing needs a sync account.
    static func authenticatorActions(for item: AuthenticatorItem, signedIn: Bool, shareCount: Int?) -> [PanelAction] {
        var actions: [PanelAction] = [.paste, .copy]
        switch item {
        case .owned:
            actions.append(.authenticator(.rename))
            if signedIn {
                actions.append(.authenticator(.share))
                // Unknown (not listed yet) counts as maybe: the form says when there's nobody.
                if shareCount != 0 {
                    actions.append(.authenticator(.people))
                    actions.append(.authenticator(.transfer))
                }
            }
            actions.append(.authenticator(.showSecret))
            actions.append(.authenticator(.delete))
        case .shared:
            if signedIn { actions.append(.authenticator(.leave)) }
        }
        return actions
    }
}

nonisolated enum AuthenticatorAction: String, Hashable, Sendable {
    case rename, share, people, transfer, showSecret, delete, leave

    var title: String {
        switch self {
        case .rename: "Edit…"
        case .share: "Share…"
        case .people: "People…"
        case .transfer: "Transfer Ownership…"
        case .showSecret: "Show Secret / QR"
        case .delete: "Delete Authenticator"
        case .leave: "Leave"
        }
    }

    var symbol: String {
        switch self {
        case .rename: "pencil"
        case .share: "person.badge.plus"
        case .people: "person.2"
        case .transfer: "arrow.right.arrow.left"
        case .showSecret: "qrcode"
        case .delete: "trash"
        case .leave: "rectangle.portrait.and.arrow.right"
        }
    }
}

/// Add (from a link, a QR code or typed) or Rename. Only the manual add shows the secret field.
@Observable
final class AuthenticatorFormState {
    enum Purpose: Equatable {
        /// `account` is set when it came from a link or QR code (its secret is never shown).
        case add(from: OTPAccount?)
        case rename(id: String)
    }

    let purpose: Purpose
    var issuer: String
    var account: String
    /// Edit → Website: the site(s) it's for, comma-separated; they pick its source in Auth.
    var website = ""
    var secret = ""
    var algorithm: OTPAlgorithm
    var digits: Int
    var period: Int
    var showsAdvanced = false
    var error: String?
    /// The one-time "keep your important codes on your phone too" note.
    let showsTip: Bool

    init(purpose: Purpose, showsTip: Bool = false) {
        self.purpose = purpose
        self.showsTip = showsTip
        switch purpose {
        case .add(let from):
            issuer = from?.issuer ?? ""
            account = from?.account ?? ""
            algorithm = from?.algorithm ?? .sha1
            digits = from?.digits ?? 6
            period = from?.period ?? 30
        case .rename:
            issuer = ""
            account = ""
            algorithm = .sha1
            digits = 6
            period = 30
        }
    }

    convenience init(renaming authenticator: Authenticator) {
        self.init(purpose: .rename(id: authenticator.id))
        issuer = authenticator.issuer
        account = authenticator.account
        website = authenticator.urls.joined(separator: ", ")
    }

    /// The sites typed into Website.
    var websites: [String] {
        SecretExtras.cleanURLs(website.split(whereSeparator: { $0 == "," || $0 == " " || $0.isNewline }).map(String.init))
    }

    var isRename: Bool { if case .rename = purpose { true } else { false } }
    /// Typed by hand: the form asks for the secret.
    var asksForSecret: Bool { purpose == .add(from: nil) }

    /// The account to add, or an error for the form.
    struct Problem: Error, Equatable { var message: String }

    func makeAccount() -> Result<OTPAccount, Problem> {
        guard case .add(let from) = purpose else { return .failure(Problem(message: "")) }
        let issuer = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !issuer.isEmpty || !account.isEmpty else { return .failure(Problem(message: "Enter an issuer or an account.")) }
        let secret: String
        if let from {
            secret = from.secret
        } else {
            guard let normalized = Base32.normalize(self.secret), Base32.decode(normalized)?.isEmpty == false else {
                return .failure(Problem(message: "That setup key isn't valid. It's the letters A–Z and digits 2–7 the site shows."))
            }
            secret = normalized
        }
        guard TOTP.digitRange.contains(digits), period > 0 else { return .failure(Problem(message: "Codes need 6 to 8 digits and a period.")) }
        return .success(OTPAccount(issuer: issuer, account: account, secret: secret, algorithm: algorithm,
                                   digits: digits, period: period))
    }
}

/// Share…, People… and Transfer Ownership… for an authenticator you own, in the panel.
@Observable
final class AuthenticatorPeopleState {
    enum Purpose { case share, people, transfer }

    let purpose: Purpose
    let authenticator: Authenticator
    var isLoading = true
    var isBusy = false
    var shares: [AuthenticatorShare] = []
    var candidates: [SharePerson] = []
    var selection = 0
    var error: String?

    init(purpose: Purpose, authenticator: Authenticator) {
        self.purpose = purpose
        self.authenticator = authenticator
    }

    /// How many rows Return can act on.
    var rowCount: Int { purpose == .share ? candidates.count : shares.count }
}

@Observable
final class SnippetFormState {
    let snippet: Snippet
    let fields: [String]
    var values: [String: String]

    init(snippet: Snippet, fields: [String]) {
        self.snippet = snippet
        self.fields = fields
        self.values = Dictionary(uniqueKeysWithValues: fields.map { ($0, "") })
    }
}

@Observable
final class SaveSecretState {
    let item: ClipItem
    var name: String

    init(item: ClipItem) {
        self.item = item
        self.name = SaveSecretState.suggestedName(for: item)
    }

    /// The item's label if it has one, else where it came from.
    static func suggestedName(for item: ClipItem) -> String {
        if let label = item.label?.trimmingCharacters(in: .whitespaces), !label.isEmpty { return label }
        return item.sourceAppName.map { "Password from \($0)" } ?? "New Secret"
    }
}

/// New Password…, New Secret… and Edit on either: name, value, and a password's sites, username
/// and notes. An existing one is filled in after Touch ID; the value lives only as long as the form.
@Observable
final class EditSecretState {
    enum Kind: Equatable { case password, secret }

    /// Nil while it's new.
    let ref: SecretRef?
    let kind: Kind
    let originalValue: String
    let originalNotes: String
    var name: String
    var value: String
    var username: String
    /// One row per site; an empty last row is where the next one is typed.
    var sites: [String]
    var notes: String
    var showsGeneratorOptions = false
    var generator = PasswordGenerator.Options()
    var error: String?

    init(ref: SecretRef, value: String, notes: String? = nil) {
        self.ref = ref
        kind = ref.isPassword ? .password : .secret
        originalValue = value
        originalNotes = notes ?? ""
        name = ref.name
        self.value = value
        username = ref.username ?? ""
        sites = ref.urls.isEmpty ? [""] : ref.urls
        self.notes = notes ?? ""
    }

    init(new kind: Kind) {
        ref = nil
        self.kind = kind
        originalValue = ""
        originalNotes = ""
        name = ""
        value = ""
        username = ""
        sites = [""]
        notes = ""
    }

    var isNew: Bool { ref == nil }

    var title: String {
        switch (isNew, kind) {
        case (true, .password): "New Password"
        case (true, .secret): "New Secret"
        case (false, .password): "Edit Password"
        case (false, .secret): "Edit Secret"
        }
    }

    /// A new secret asks only for a name and a value; everything else shows sites and username.
    var showsPasswordFields: Bool { kind == .password || !isNew }

    var cleanSites: [String] { SecretExtras.cleanURLs(sites) }

    func addSite() {
        if sites.last?.trimmingCharacters(in: .whitespaces).isEmpty != true { sites.append("") }
    }

    func removeSite(at index: Int) {
        guard sites.indices.contains(index) else { return }
        sites.remove(at: index)
        if sites.isEmpty { sites = [""] }
    }

    func generate() {
        value = PasswordGenerator.generate(generator)
    }

    /// The name to save under: as typed, or for a password its site, else its username.
    var resolvedName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty || !showsPasswordFields { return typed }
        if let site = cleanSites.first { return AuthSource.domain(ofSite: site) ?? site }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return user.isEmpty ? (kind == .password ? "Password" : "") : user
    }

    var canSave: Bool { !resolvedName.isEmpty && !value.isEmpty }
}

/// Picks the sync group that the selected items are copied into.
@Observable
final class ShareGroupState {
    let items: [ClipItem]
    /// Set when sharing a secret instead of clips; its value is read (after Touch ID) only on submit.
    let secret: SecretRef?
    /// Set when sharing a Saved folder: it's copied with its clips (`items`).
    let folder: ClipFolder?
    let groups: [SyncGroup]
    var selection: Int {
        didSet { if selection != oldValue { destinationID = nil } }
    }
    /// Set when a text item looks like a password or key, so the form warns before it's shared.
    let sensitiveKind: SensitiveText.Kind?
    /// Each group's folders (by name), offered as the destination of clips and secrets.
    let foldersByGroup: [String: [ClipFolder]]
    /// The chosen group's folder the copies go in; nil is the root (the default).
    var destinationID: UUID?

    init(items: [ClipItem] = [], secret: SecretRef? = nil, folder: ClipFolder? = nil, groups: [SyncGroup],
         defaultGroupID: String?, foldersByGroup: [String: [ClipFolder]] = [:]) {
        self.items = items
        self.secret = secret
        self.folder = folder
        self.groups = groups
        self.selection = groups.firstIndex { $0.id == defaultGroupID } ?? 0
        self.sensitiveKind = items.contains(where: \.isConcealed) ? .authenticatorQR
            : items.lazy.filter(\.kind.isTextual).compactMap { SensitiveText.detect($0.text) }.first
        // A folder is copied as a folder (folders don't nest), so it has no destination.
        self.foldersByGroup = folder == nil ? foldersByGroup : [:]
    }

    var selectedGroup: SyncGroup? { groups.indices.contains(selection) ? groups[selection] : nil }

    /// The chosen group's folders: the destinations besides the root.
    var destinations: [ClipFolder] { selectedGroup.flatMap { foldersByGroup[$0.id] } ?? [] }

    /// The chosen destination, if it's (still) one of the chosen group's folders.
    var destination: ClipFolder? { destinations.first { $0.id == destinationID } }

    /// ← → walk Root, then each folder.
    func moveDestination(by delta: Int) {
        let choices: [UUID?] = [nil] + destinations.map(\.id)
        guard choices.count > 1 else { return }
        let current = choices.firstIndex { $0 == destination?.id } ?? 0
        destinationID = choices[min(max(current + delta, 0), choices.count - 1)]
    }
}

@Observable
final class LabelFormState {
    enum Target {
        case clip(ClipItem)
        case secret(SecretRef)
        case folder(ClipFolder)
        /// Several selected clips get the same label (⌘L on a selection).
        case clips([ClipItem])
    }

    let target: Target
    var text: String

    init(target: Target) {
        self.target = target
        switch target {
        case .clip(let item): text = item.label ?? ""
        case .secret(let ref): text = ref.name
        case .folder(let folder): text = folder.label ?? ""
        case .clips(let items):
            // Their shared label, if they all have the same one.
            let labels = Set(items.map { $0.label ?? "" })
            text = labels.count == 1 ? labels.first ?? "" : ""
        }
    }

    var valuePreview: String {
        switch target {
        case .clip(let item): item.preview.isEmpty ? item.kind.displayName : item.preview
        case .secret: "••••••••"
        case .folder(let folder): folder.name
        case .clips(let items): "\(items.count) items"
        }
    }

    var isSecret: Bool {
        if case .secret = target { return true }
        return false
    }

    var isFolder: Bool {
        if case .folder = target { return true }
        return false
    }
}

/// The Folder row's picker: the items' space as a tree (plus "Mine" for a group's items), the top
/// level and New Folder… at each level. ↑↓ choose, Return picks.
@Observable
final class FolderPickerState {
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case topLevel
            case folder(ClipFolder)
            /// A new folder at that level (nil: top level), the items move into it.
            case newFolder(parent: ClipFolder?, personal: Bool)
        }
        var id: String
        var title: String
        var level: Int
        var kind: Kind
        /// Section heading shown above it ("Team", "Mine").
        var section: String?

        static func == (a: Row, b: Row) -> Bool { a.id == b.id }
    }

    let clips: [ClipItem]
    let secrets: [SecretRef]
    let rows: [Row]
    var selection = 0

    init(clips: [ClipItem], secrets: [SecretRef], menu: PanelViewModel.FolderMenu, groupFolders: [ClipFolder],
         personalFolders: [ClipFolder]) {
        self.clips = clips
        self.secrets = secrets
        var rows: [Row] = []
        func tree(_ folders: [ClipFolder], allowed: Set<UUID>?, personal: Bool, section: String?, prefix: String) {
            let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let tree = FolderTree(folders)
            var first = true
            for (node, level) in tree.flattened() {
                guard let folder = byID[node.id], allowed?.contains(node.id) ?? true else { continue }
                rows.append(Row(id: prefix + node.id.uuidString, title: node.name, level: level, kind: .folder(folder),
                                section: first ? section : nil))
                first = false
            }
            rows.append(Row(id: prefix + "new", title: "New Folder…", level: 0, kind: .newFolder(parent: nil, personal: personal),
                            section: first ? section : nil))
        }
        if let group = menu.group {
            rows.append(Row(id: "top", title: "Top Level of \(group.name)", level: 0, kind: .topLevel, section: group.name))
            tree(groupFolders, allowed: nil, personal: false, section: nil, prefix: "g-")
            tree(personalFolders, allowed: nil, personal: true, section: "Mine", prefix: "m-")
        } else if menu.copiesToPersonal {
            tree(personalFolders, allowed: nil, personal: true, section: "Mine", prefix: "m-")
        } else {
            rows.append(Row(id: "top", title: "Top Level", level: 0, kind: .topLevel))
            tree(personalFolders, allowed: nil, personal: false, section: nil, prefix: "m-")
        }
        self.rows = rows
    }

    var count: Int { clips.count + secrets.count }
}

/// Add Items in the Saved header: recent unsaved history of this space, checked to save here.
/// Also Send… on a contact in Contacts → People: recent history, checked to send to them.
@Observable
final class AddItemsState {
    let candidates: [ClipItem]
    /// The open folder they go into; nil: the top level of Saved.
    let folder: ClipFolder?
    /// Send… : the contact they go to (instead of Saved).
    let contact: SyncContact?
    var query = "" { didSet { if query != oldValue { selection = 0 } } }
    var checked: Set<UUID> = []
    var selection = 0

    init(candidates: [ClipItem], folder: ClipFolder?, contact: SyncContact? = nil) {
        self.candidates = candidates
        self.folder = folder
        self.contact = contact
    }

    /// The candidates matching the search, newest first.
    var shown: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return candidates }
        return candidates.filter { FuzzyMatcher.score(query: q, in: $0.searchableText) != nil }
    }

    func toggle(_ item: ClipItem) {
        if checked.contains(item.id) { checked.remove(item.id) } else { checked.insert(item.id) }
    }

    func toggleSelected() {
        let items = shown
        guard items.indices.contains(selection) else { return }
        toggle(items[selection])
    }
}

/// The name of a folder being renamed or created, typed in the panel (never a dialog).
@Observable
final class FolderNameState {
    enum Purpose {
        case rename(ClipFolder)
        /// A new folder in `spaceID`; `moving` clips and `secrets` go into it (as personal copies
        /// when they're group items and the folder is personal).
        case create(spaceID: String?, moving: [ClipItem], secrets: [SecretRef] = [])
    }

    let purpose: Purpose
    var name: String
    /// A new folder goes in this one (same space); nil at the top level.
    let parent: ClipFolder?

    init(purpose: Purpose, parent: ClipFolder? = nil) {
        self.purpose = purpose
        self.parent = parent
        switch purpose {
        case .rename(let folder): name = folder.name
        case .create: name = "New Folder"
        }
    }

    var isRename: Bool {
        if case .rename = purpose { return true }
        return false
    }

    var movingCount: Int {
        if case .create(_, let moving, let secrets) = purpose { return moving.count + secrets.count }
        return 0
    }

    /// The new folder is personal and takes copies of group items.
    var copies: Bool {
        guard case .create(let space, let moving, let secrets) = purpose, space == nil else { return false }
        return moving.contains { $0.spaceID != nil } || secrets.contains { $0.spaceID != nil }
    }
}

@Observable
final class PanelViewModel {
    @ObservationIgnored let env: AppEnvironment
    @ObservationIgnored var onClose: () -> Void = {}

    var query = "" { didSet { if query != oldValue { refresh(resetSelection: true) } } }
    var filter: PanelFilter = .copies {
        didSet {
            guard filter != oldValue else { return }
            openFolderID = nil
            // Groups shows one group at a time: the last one, else the first.
            if filter == .groups, groupFilter == nil {
                groupFilter = rememberedGroupID
                if groupFilter != nil { return }   // its didSet refreshed
            } else if filter != .groups, groupFilter != nil {
                groupFilter = nil
                return
            }
            refresh(resetSelection: true)
            // Fetch what contacts sent since the last sync; the list refreshes when it lands.
            if filter == .inbox { env.sync.syncNow() }
        }
    }
    /// The group shown in the Groups chip (nil outside it, or without groups).
    var groupFilter: String? {
        didSet {
            guard groupFilter != oldValue else { return }
            openFolderID = nil
            if let groupFilter {
                UserDefaults.standard.set(groupFilter, forKey: "panelLastGroup")
                if filter != .groups { filter = .groups }
            }
            refresh(resetSelection: true)
            // Fetch what group members sent since the last sync; the list refreshes when it lands.
            if groupFilter != nil { env.sync.syncNow() }
        }
    }

    /// The group Groups opens on: the last one shown, else the first.
    var rememberedGroupID: String? {
        let groups = env.sync.groups
        let last = UserDefaults.standard.string(forKey: "panelLastGroup")
        return groups.first { $0.id == last }?.id ?? groups.first?.id
    }

    /// Copies' "Only from ‹App›" toggle: just what was copied in the app the panel pastes into.
    var onlyThisApp = false {
        didSet { if onlyThisApp != oldValue { refresh(resetSelection: true) } }
    }

    // MARK: Saved and folders

    /// The folder open in the Saved list (nil: its root).
    private(set) var openFolderID: UUID?
    /// Number of saved clips and secrets in each folder of the Saved list being shown.
    private(set) var folderCounts: [UUID: Int] = [:]
    /// Number of subfolders in each folder of the Saved list being shown.
    private(set) var subfolderCounts: [UUID: Int] = [:]
    /// Search results below the open folder (or the root), by entry id: their folder's path
    /// relative to where you are ("Work › Clients"), shown under them.
    private(set) var folderCaptions: [String: String] = [:]
    /// The folders of the Saved list being shown, as a tree (refreshed with the list).
    private(set) var savedTree = FolderTree(nodes: [])
    /// A folder row being dragged (drops on itself or below it are refused while it's set).
    var draggingFolderID: UUID?
    /// Groups showing their Saved items instead of their Copies (remembered per group).
    private(set) var groupsShowingSaved: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "panelGroupsShowingSaved") ?? [])

    /// The selected group pill's Copies | Saved segment.
    var groupShowsSaved: Bool {
        get { groupFilter.map(groupsShowingSaved.contains) ?? false }
        set {
            guard let groupFilter, newValue != groupShowsSaved else { return }
            if newValue { groupsShowingSaved.insert(groupFilter) } else { groupsShowingSaved.remove(groupFilter) }
            UserDefaults.standard.set(Array(groupsShowingSaved).sorted(), forKey: "panelGroupsShowingSaved")
            openFolderID = nil
            refresh(resetSelection: true)
        }
    }

    /// The list shows Auth: your secrets and authenticators.
    var isAuthView: Bool { selectionItem == nil && groupFilter == nil && filter == .auth }

    /// The list shows Saved: the Saved chip, or a group switched to Saved.
    var isSavedView: Bool {
        groupFilter == nil ? filter == .labelled && selectionItem == nil : groupShowsSaved
    }

    /// The space whose Saved items are shown (nil: personal).
    var savedSpaceID: String? { groupFilter }

    var openFolder: ClipFolder? {
        guard isSavedView, let openFolderID, let folder = env.store.folder(withID: openFolderID),
              folder.spaceID == savedSpaceID else { return nil }
        return folder
    }

    func openFolder(_ folder: ClipFolder) {
        guard isSavedView, folder.spaceID == savedSpaceID else { return }
        openFolderID = folder.id
        query = ""
        refresh(resetSelection: true)
        userMovedSelection = false
    }

    /// Up one level (to the parent folder, or the root of Saved), with the folder selected.
    func closeFolder() {
        guard let id = openFolderID else { return }
        openFolderID = savedTree.parent(of: id)
        query = ""
        refresh(resetSelection: true)
        if entries.contains(where: { $0.id == "f-" + id.uuidString }) { selectedID = "f-" + id.uuidString }
    }

    /// Jumps to a breadcrumb segment: a folder of the path, or (nil) the root of Saved.
    func showLevel(_ folderID: UUID?) {
        guard isSavedView, folderID != openFolderID else { return }
        let from = openFolderID
        openFolderID = folderID
        query = ""
        refresh(resetSelection: true)
        // The child on the way back down is selected, like going up one level.
        if let from, let child = savedTree.path(to: from).first(where: { savedTree.parent(of: $0.id) == folderID }) {
            let id = "f-" + child.id.uuidString
            if entries.contains(where: { $0.id == id }) { selectedID = id }
        }
    }

    /// The open folder's path from the top level ("Work", "Clients").
    var openFolderPath: [ClipFolder] {
        guard isSavedView, let openFolderID else { return [] }
        return savedTree.path(to: openFolderID).compactMap { env.store.folder(withID: $0.id) }
    }
    private(set) var entries: [PanelEntry] = []
    /// Date headings ("Today", "Yesterday"…) keyed by the first row under each; empty while searching.
    private(set) var sectionStarts: [String: String] = [:]
    /// Auth's source headings, keyed by the first row under each (nil source: "No website"); empty while searching.
    private(set) var authSourceStarts: [String: AuthSourceHeading] = [:]
    /// ⌘ is down: every row shows its ⌘-number, not just the selected one.
    var isCommandHeld = false
    /// Which tip the hint bar shows; moves on with every open.
    var tipIndex = 0
    /// The focused row (drives the preview and keyboard navigation).
    var selectedID: String? {
        didSet {
            if selectedID != oldValue {
                clearPickedFiles()
                if previewSelection != nil { previewSelection = nil }
                if revealedSecretID != nil { revealedSecretID = nil }
                if pendingDeleteID != nil { pendingDeleteID = nil }
            }
            guard !adjustingSelection else { return }
            selectedIDs = selectedID.map { [$0] } ?? []
            anchorID = selectedID
        }
    }
    /// Every selected row; more than one after ⌘-click, ⇧-click, ⇧-arrows or ⌘A.
    private(set) var selectedIDs: Set<String> = [] {
        didSet { if selectedIDs != oldValue { onQuickLookItemsChanged() } }
    }
    @ObservationIgnored private var anchorID: String?
    @ObservationIgnored private var adjustingSelection = false
    /// Bumped each time the panel opens so the view can refocus the search field.
    private(set) var focusToken = 0

    private(set) var mode: PanelMode = .browse {
        // Returning to the list hands keyboard focus back to the search field.
        didSet { if mode == .browse && oldValue != .browse { focusToken &+= 1 } }
    }
    var actionQuery = "" { didSet { if actionQuery != oldValue { actionSelection = 0 } } }
    var actionSelection = 0
    private(set) var snippetForm: SnippetFormState?
    private(set) var saveSecretForm: SaveSecretState?
    private(set) var labelForm: LabelFormState?
    private(set) var saveForm: SaveFormState?
    private(set) var editSecretForm: EditSecretState?
    private(set) var shareForm: ShareGroupState?
    private(set) var folderNameForm: FolderNameState?
    private(set) var authenticatorForm: AuthenticatorFormState?
    private(set) var peopleForm: AuthenticatorPeopleState?
    private(set) var folderPicker: FolderPickerState?
    private(set) var addItemsForm: AddItemsState?
    private(set) var contactPicker: ContactPickerState?
    private(set) var addContactForm: AddContactState?
    /// Contacts shows People (requests and contacts) instead of the Inbox.
    var contactsShowPeople = false {
        didSet {
            guard contactsShowPeople != oldValue else { return }
            pendingRemoveContactID = nil
            refresh(resetSelection: true)
            if contactsShowPeople { Task { await env.sync.refreshContacts(); refresh() } }
        }
    }
    /// Contacts → People's rows, after `refresh()`.
    private(set) var people: [PeopleRow] = []
    /// The selected row of People.
    var peopleSelectionID: String? {
        didSet { if peopleSelectionID != oldValue { pendingRemoveContactID = nil } }
    }
    /// The contact waiting for Remove's inline confirm.
    private(set) var pendingRemoveContactID: String?
    /// When you last sent each contact something or got something from them, by space id.
    private(set) var lastExchange: [String: Date] = [:]
    /// Touch ID before secrets leave for a contact (tests replace it).
    @ObservationIgnored var authenticateSecrets: ((String) async -> Bool)?
    /// Ticks once a second while the panel is open, for authenticator codes and their rings.
    @ObservationIgnored let otpClock = OTPClock()
    /// The authenticator whose secret and QR code are showing (after Touch ID); cleared on any move.
    private(set) var revealedSecretID: String?
    /// The authenticator waiting for its inline Delete confirm.
    private(set) var pendingDeleteID: String?
    /// Enter waits for the next code when fewer than 3 s are left.
    @ObservationIgnored private var codeWait: Task<Void, Never>?
    private(set) var aiRun: AIRun?
    /// Transient status line ("Copied", "Not valid JSON", …).
    private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    /// The app that was frontmost when the panel opened — pastes go here.
    private(set) var targetApp: NSRunningApplication?
    var targetRef: AppRef? { targetApp.flatMap(FrontmostAppTracker.ref(for:)) }

    static let maxEntries = 300

    init(env: AppEnvironment) {
        self.env = env
        quickLookFiles = QuickLookFiles(blobs: env.blobs, directory: AppPaths.quickLookDirectory)
    }

    // MARK: Lifecycle

    /// Text selected in another app (via ⌥⌘K or the Services menu). It's a transient item:
    /// never saved to history unless the user explicitly saves it.
    private(set) var selectionItem: ClipItem?

    var isSelectionMode: Bool { selectionItem != nil }

    func prepareForSelection(_ text: String, target: NSRunningApplication?) {
        prepareForOpen(target: target)
        let item = ClipItem(capture: .text(text, source: target.flatMap(FrontmostAppTracker.ref(for:))))
        selectionItem = item
        entries = [.clip(item)]
        selectedID = PanelEntry.clip(item).id
        actionQuery = ""
        mode = .actions
    }

    func prepareForOpen(target: NSRunningApplication?) {
        selectionItem = nil
        resetMode()
        notice = nil
        targetApp = target
        query = ""
        // Back to Copies without the group pill animating closed behind the opening panel.
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            groupFilter = nil
            filter = .copies
            onlyThisApp = false
        }
        openFolderID = nil
        userMovedSelection = false
        isCommandHeld = false
        tipIndex &+= 1
        env.sync.periodicSync()
        env.emailCodes.fetchNow()
        refresh(resetSelection: true)
        focusToken &+= 1
        openToken &+= 1
        otpClock.start()
    }

    /// Bumped on every open so the list scrolls back to the top.
    private(set) var openToken = 0
    /// Until the user moves the selection, it stays on the newest item — even when a copy made
    /// just before opening lands a moment later.
    @ObservationIgnored private var userMovedSelection = false

    func didClose() {
        flushEditor?()
        isEditingText = false
        selectionItem = nil
        previewSelection = nil
        clearPickedFiles()
        resetMode()
        otpClock.stop()
        codeWait?.cancel()
        codeWait = nil
        revealedSecretID = nil
        pendingDeleteID = nil
    }

    // MARK: Picking files of a multi-file item

    /// Files chosen in the preview of the selected multi-file item. While some (not all) are
    /// chosen, paste, copy, save and drag use only those; the item itself is unchanged.
    private(set) var pickedFiles: Set<URL> = [] {
        didSet { if pickedFiles != oldValue { onQuickLookItemsChanged() } }
    }
    @ObservationIgnored private var pickedFileAnchor: URL?

    /// Click toggles a file, ⇧-click adds the range from the last clicked one.
    func clickFile(_ url: URL, in item: ClipItem) {
        if NSEvent.modifierFlags.contains(.shift) {
            extendPickedFiles(to: url, in: item)
        } else {
            togglePickedFile(url)
        }
    }

    func togglePickedFile(_ url: URL) {
        if pickedFiles.contains(url) { pickedFiles.remove(url) } else { pickedFiles.insert(url) }
        pickedFileAnchor = url
    }

    func extendPickedFiles(to url: URL, in item: ClipItem) {
        let urls = item.fileURLs
        guard let anchor = pickedFileAnchor, let from = urls.firstIndex(of: anchor), let to = urls.firstIndex(of: url) else {
            togglePickedFile(url)
            return
        }
        pickedFiles.formUnion(urls[min(from, to)...max(from, to)])
        pickedFileAnchor = url
    }

    func clearPickedFiles() {
        if !pickedFiles.isEmpty { pickedFiles = [] }
        pickedFileAnchor = nil
    }

    /// The chosen files of `item` in item order, or nil when the whole item applies (nothing or
    /// everything chosen, another item, or several rows selected).
    func pickedFileURLs(for item: ClipItem) -> [URL]? {
        guard !pickedFiles.isEmpty, item.kind == .file, !isMultiSelecting, selectedEntry?.clip?.id == item.id else { return nil }
        let urls = item.fileURLs.filter(pickedFiles.contains)
        return urls.isEmpty || urls.count == item.fileURLs.count ? nil : urls
    }

    /// "2 of 3" for the footer and the preview while a subset is chosen.
    var pickedFileCount: (picked: Int, total: Int)? {
        guard let item = selectedEntry?.clip, let urls = pickedFileURLs(for: item) else { return nil }
        return (urls.count, item.fileURLs.count)
    }

    /// Copies the item, or just its chosen files.
    func copy(_ item: ClipItem) {
        if let files = pickedFileURLs(for: item) {
            env.paste.write(fileURLs: files)
        } else {
            env.paste.copy(item)
        }
    }

    // MARK: Editing the previewed text

    /// The preview's text editor has keyboard focus (keys go to it, not the list).
    var isEditingText = false
    /// Bumped by ⌘E to move keyboard focus into the editor.
    private(set) var editorFocusToken = 0
    /// Set by the editor: saves pending edits now (before pasting or closing).
    @ObservationIgnored var flushEditor: (() -> Void)?
    /// Set by the editor: styles the selection (style bar and ⌘B/⌘I/⌘U).
    @ObservationIgnored var applyStyle: (TextStyle) -> Void = { _ in }

    /// Only this account's own plain text items: transient selections aren't saved, group items
    /// belong to everyone in the group, and recognised content (a color, a link, JSON, a password…)
    /// keeps its own preview.
    func isEditable(_ item: ClipItem) -> Bool {
        item.kind.isTextual && !item.isTransient && item.spaceID == nil && ClipContentCache.content(of: item) == .plain
    }

    func beginEditing() {
        guard let item = selectedEntry?.clip, isEditable(item), !isMultiSelecting else { return }
        editorFocusToken &+= 1
    }

    /// Saves and hands the keyboard back to the search field and list.
    func endEditing() {
        flushEditor?()
        isEditingText = false
        focusToken &+= 1
    }

    func saveEdit(_ item: ClipItem, text: String, rtf: Data?, html: Data?) {
        env.store.editText(of: item, text: text, rtf: rtf, html: html)
    }

    /// Keys while the editor has focus: everything is typing except leaving and pasting.
    func handleEditorKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case KeyCode.escape:
            endEditing()
            return true
        // With text selected in the editor, Return (or ⌘Return) pastes just that.
        case KeyCode.returnKey where previewSelection != nil && !flags.contains(.shift) && !flags.contains(.option),
             KeyCode.keypadEnter where previewSelection != nil:
            flushEditor?()
            pastePreviewSelection()
            return true
        case KeyCode.returnKey where flags.contains(.command), KeyCode.keypadEnter where flags.contains(.command):
            flushEditor?()
            isEditingText = false
            activate(selectedEntry, transform: flags.contains(.option) ? .plainText : nil)
            return true
        default:
            // ⌘C copies the selection as plain text, without a new history item.
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c", previewSelection != nil {
                copyPreviewSelection()
                return true
            }
            return false
        }
    }

    // MARK: Part of a text

    /// Text selected in the preview pane (an item's text, or the words in an image): Return
    /// and ⌘C use just this. Cleared when the row changes or the user clicks elsewhere.
    var previewSelection: String?

    /// Pastes the preview's selection as plain text. The clip stays as it is, and no history
    /// item is added (the write is marked as our own).
    func pastePreviewSelection() {
        guard let text = previewSelection, !text.isEmpty else { return }
        pasteText(text)
    }

    func copyPreviewSelection() {
        guard let text = previewSelection, !text.isEmpty else { return }
        env.paste.write(text: text)
        showNotice("Copied selection")
    }

    // MARK: Keep Open

    /// Kept open: the panel stays up after pasting, on focus loss, esc and ⇧⌘V. Not remembered.
    var isPinned = false

    /// Kept open, pastes go to whichever app the user was last in.
    func retarget(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != targetApp?.processIdentifier else { return }
        targetApp = app
        refresh()
    }

    func focusSearch() {
        focusToken &+= 1
    }

    func resetMode() {
        aiRun?.cancel()
        aiRun = nil
        snippetForm = nil
        saveSecretForm = nil
        labelForm = nil
        saveForm = nil
        editSecretForm = nil
        shareForm = nil
        folderNameForm = nil
        authenticatorForm = nil
        peopleForm = nil
        folderPicker = nil
        addItemsForm = nil
        contactPicker = nil
        addContactForm = nil
        actionQuery = ""
        actionSelection = 0
        mode = .browse
        focusToken &+= 1
    }

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func refresh(resetSelection: Bool = false) {
        refreshLastExchange()
        if let selectionItem {
            entries = [.clip(selectionItem)]
            selectedID = PanelEntry.clip(selectionItem).id
            return
        }
        if showsPeople {
            refreshPeople(resetSelection: resetSelection)
            entries = []
            sectionStarts = [:]
            selectedID = nil
            return
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetBundle = targetApp?.bundleIdentifier

        var clips: [ClipItem] = []
        var folders: [ClipFolder] = []
        var snippets: [Snippet] = []
        var secrets: [SecretRef] = []
        var authenticators: [AuthenticatorItem] = []
        folderCaptions = [:]
        let savedView = isSavedView
        let authView = groupFilter == nil && filter == .auth
        // Codes from email (phase 4): live ones only, newest first.
        let emailCodes = authView ? EmailCodeCenter.live(env.emailCodes.codes, at: .now) : []
        if authView {
            (secrets, authenticators) = authList()
        } else if savedView {
            // Saved: everything one space keeps. Folder rows first (by name), then its saved clips,
            // secrets and snippets mixed, newest first; inside a folder only its clips and secrets.
            // Searching from the root finds what's in folders too, captioned with the folder's name.
            let all = env.store.folders(inSpace: savedSpaceID)
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let tree = FolderTree(all)
            savedTree = tree
            let saved = env.store.items(inSpace: savedSpaceID).filter(\.isPinned)
            // Your own secrets live in Auth; a group's Saved still lists the group's.
            let spaceSecrets = savedSpaceID == nil ? [] : env.secrets.secrets.filter { $0.spaceID == savedSpaceID }
            if let open = openFolderID, byID[open] == nil { openFolderID = nil }   // deleted meanwhile
            // The folder something shows in: nil (the root) when it has none or one that isn't here.
            let place = { (id: UUID?) -> UUID? in id.flatMap { byID[$0] != nil ? $0 : nil } }
            var counts: [UUID: Int] = [:]
            for id in saved.compactMap({ place($0.folderID) }) + spaceSecrets.compactMap({ place($0.folderID) }) {
                counts[id, default: 0] += 1
            }
            folderCounts = counts
            subfolderCounts = Dictionary(all.map { ($0.id, tree.children(of: $0.id).count) }, uniquingKeysWith: { first, _ in first })
            let open = openFolderID
            if open == nil { snippets = env.snippets.snippets(inSpace: savedSpaceID) }
            if q.isEmpty {
                // This level: its subfolders (by name), then its items.
                folders = tree.children(of: open).compactMap { byID[$0.id] }
                clips = saved.filter { place($0.folderID) == open }
                secrets = spaceSecrets.filter { place($0.folderID) == open }
            } else {
                // The whole subtree below where you are, each result captioned with its path from here.
                let scope: Set<UUID>? = open.map { tree.descendants(of: $0) }
                let inScope = { (folder: UUID?) -> Bool in
                    guard let scope else { return true }
                    return folder == open || folder.map(scope.contains) == true
                }
                folders = all.filter { scope?.contains($0.id) ?? true }
                clips = saved.filter { inScope(place($0.folderID)) }
                secrets = spaceSecrets.filter { inScope(place($0.folderID)) }
                let caption = { (folder: UUID?) -> String? in
                    guard let folder, folder != open else { return nil }
                    return tree.pathName(of: folder, relativeTo: open)
                }
                for item in clips { folderCaptions[PanelEntry.clip(item).id] = caption(place(item.folderID)) }
                for ref in secrets { folderCaptions[PanelEntry.secret(ref).id] = caption(place(ref.folderID)) }
                for folder in folders { folderCaptions[PanelEntry.folder(folder).id] = caption(tree.parent(of: folder.id)) }
            }
        } else if let groupFilter {
            clips = env.store.allItems().filter { $0.spaceID == groupFilter }
        } else if filter == .inbox {
            // What contacts send lives in the Inbox only; what you sent them isn't listed again.
            clips = env.store.allItems().filter(env.sync.isFromContact)
            secrets = env.secrets.secrets.filter(env.sync.isFromContact(secret:))
        } else if filter == .copies {
            // Your own history only: never a group's or a contact's items.
            let onlyFrom = onlyThisApp ? targetBundle : nil
            clips = env.store.allItems().filter { item in
                item.spaceID == nil && (!onlyThisApp || (onlyFrom != nil && item.sourceBundleID == onlyFrom))
            }
        }
        // Groups without a group to show (none yet) lists nothing.

        var result: [PanelEntry]
        var authStarts: [String: AuthSourceHeading] = [:]
        if q.isEmpty && authView {
            // Grouped by source, the most recently used first; "No website" last.
            let groups = Self.authGroups(secrets: secrets, authenticators: authenticators,
                                         lastUsed: AuthSourceUsage.shared.lastUsed)
            // "Email codes" first; each code again under its source, when that source is listed.
            result = emailCodes.map { PanelEntry.emailCode($0) }
            for group in groups {
                let items = Self.emailCodeEntries(emailCodes, under: group.source) + group.items
                if let first = items.first { authStarts[first.id] = AuthSourceHeading(source: group.source) }
                result += items
            }
        } else if q.isEmpty && savedView {
            let kept = clips.map(PanelEntry.clip) + secrets.map(PanelEntry.secret) + snippets.map(PanelEntry.snippet)
                + authenticators.map(PanelEntry.authenticator)
            result = folders.map(PanelEntry.folder) + kept.sorted { $0.savedDate > $1.savedDate }
        } else if q.isEmpty && groupFilter == nil && filter == .inbox {
            // What contacts sent, newest first, secrets among the clips.
            let dated = clips.map { (PanelEntry.clip($0), $0.lastCopiedAt) } + secrets.map { (PanelEntry.secret($0), $0.createdAt ?? .distantPast) }
            result = dated.sorted { $0.1 > $1.1 }.map(\.0)
        } else if q.isEmpty {
            result = clips.map(PanelEntry.clip) + snippets.map(PanelEntry.snippet) + secrets.map(PanelEntry.secret)
            // A copied authenticator link or QR code: offered once, at the top of All.
            if groupFilter == nil, filter == .copies, let suggestion = env.authenticators.suggestion {
                result.insert(.authenticatorSuggestion(suggestion), at: 0)
            }
        } else {
            var scored: [(PanelEntry, Int, Date)] = []
            for folder in folders {
                // Folders whose name matches come first.
                if let s = FuzzyMatcher.score(query: q, in: folder.name + (folder.label.map { " " + $0 } ?? "")) {
                    scored.append((.folder(folder), s + 1_000, folder.createdAt))
                }
            }
            for item in clips {
                if let s = FuzzyMatcher.score(query: q, in: item.searchableText) {
                    scored.append((.clip(item), s, item.lastCopiedAt))
                }
            }
            let lowered = q.lowercased()
            for snippet in snippets {
                let keywordHit = !snippet.keyword.isEmpty && snippet.keyword.lowercased() == lowered
                let haystack = snippet.name + " " + snippet.keyword + " " + snippet.body
                if let s = FuzzyMatcher.score(query: q, in: haystack) {
                    scored.append((.snippet(snippet), s + (keywordHit ? 10_000 : 0), snippet.updatedAt))
                } else if keywordHit {
                    scored.append((.snippet(snippet), 10_000, snippet.updatedAt))
                }
            }
            for secret in secrets {
                // Names, usernames and sites only — values never leave the keychain for search.
                if let s = FuzzyMatcher.score(query: q, in: Self.authSearchText(secret)) {
                    scored.append((.secret(secret), s + 500, secret.createdAt ?? .distantPast))
                }
            }
            for item in authenticators {
                // Issuer, account and sites only; never the secret.
                if let s = FuzzyMatcher.score(query: q, in: Self.authSearchText(item)) {
                    scored.append((.authenticator(item), s + 500, item.createdAt))
                }
            }
            for code in emailCodes {
                // By source only.
                if let s = FuzzyMatcher.score(query: q, in: code.source) {
                    scored.append((.emailCode(code), s + 600, code.receivedAt))
                }
            }
            scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 > $1.2 }
            result = scored.map(\.0)
        }

        entries = Array(result.prefix(Self.maxEntries))
        authSourceStarts = authStarts
        sectionStarts = q.isEmpty && !authView ? Self.dateSections(entries, date: savedView ? { $0.folder == nil ? $0.savedDate : nil }
                                                                         : { $0.clip?.lastCopiedAt ?? $0.secret?.createdAt }) : [:]
        if q.isEmpty && authView, let first = emailCodes.first {
            sectionStarts[PanelEntry.emailCode(first).id] = "Email codes"
        }
        if resetSelection || !userMovedSelection || !entries.contains(where: { $0.id == selectedID }) {
            selectedID = entries.first?.id
        } else {
            let live = Set(entries.map(\.id))
            setSelection(selectedIDs.intersection(live), focus: selectedID)
        }
    }

    /// What Auth lists: your secrets and your groups' (never a contact's, those are in the
    /// Inbox), and every authenticator, yours or shared with you. Names only; nothing is unlocked.
    func authList() -> (secrets: [SecretRef], authenticators: [AuthenticatorItem]) {
        let secrets = env.secrets.secrets.filter { $0.spaceID == nil || isGroupSpace($0.spaceID) }
        return (secrets, env.authenticators.items)
    }

    /// Auth's rows by source (docs/features/auth-autofill.md → Sources).
    static func authGroups(secrets: [SecretRef], authenticators: [AuthenticatorItem],
                           lastUsed: [String: Date]) -> [AuthSourceGroup<PanelEntry>] {
        let entries = secrets.map(PanelEntry.secret) + authenticators.map(PanelEntry.authenticator)
        return AuthSourceGrouping.group(entries, source: authSource(of:), title: authTitle, lastUsed: lastUsed)
    }

    /// The email codes listed again under a source (none under "No website").
    static func emailCodeEntries(_ codes: [EmailCode], under source: AuthSource?) -> [PanelEntry] {
        guard let domain = source?.domain else { return [] }
        return codes.filter { $0.source == domain }.map { PanelEntry.emailCode($0, inSource: true) }
    }

    /// The source a row in Auth sits under.
    static func authSource(of entry: PanelEntry) -> AuthSource? {
        switch entry {
        case .secret(let ref): AuthSource.of(ref)
        case .authenticator(let item): AuthSource.of(item)
        default: nil
        }
    }

    /// Within a source: a password by its username, a secret by its name, an authenticator by its title.
    private static func authTitle(_ entry: PanelEntry) -> String {
        switch entry {
        case .secret(let ref): ref.username ?? ref.name
        case .authenticator(let item): item.title
        default: ""
        }
    }

    /// What search sees of a secret or password: never its value or notes.
    static func authSearchText(_ ref: SecretRef) -> String {
        ([ref.name, ref.username ?? "", AuthSource.of(ref)?.name ?? ""] + ref.urls).joined(separator: " ")
    }

    /// What search sees of an authenticator: never its secret or codes.
    static func authSearchText(_ item: AuthenticatorItem) -> String {
        ([item.searchText, AuthSource.of(item)?.name ?? ""] + item.urls).joined(separator: " ")
    }

    /// Pasting or copying from a source moves it to the top of Auth.
    func noteAuthUse(_ entry: PanelEntry) {
        AuthSourceUsage.shared.record(Self.authSource(of: entry))
    }

    /// Today, Yesterday, This Week, Earlier: the first row of each, in list (newest-first) order.
    private static func dateSections(_ entries: [PanelEntry], date entryDate: (PanelEntry) -> Date?,
                                     now: Date = .now) -> [String: String] {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)) ?? now
        var starts: [String: String] = [:]
        var current: String?
        for entry in entries {
            guard let date = entryDate(entry) else { continue }
            let title = calendar.isDateInToday(date) ? "Today"
                : calendar.isDateInYesterday(date) ? "Yesterday"
                : date >= weekAgo ? "This Week" : "Earlier"
            if title != current {
                starts[entry.id] = title
                current = title
            }
        }
        return starts
    }

    // MARK: Selection

    var selectedIndex: Int? { entries.firstIndex { $0.id == selectedID } }

    var selectedEntry: PanelEntry? {
        selectedIndex.map { entries[$0] }
    }

    func moveSelection(by delta: Int, extending: Bool = false) {
        guard !entries.isEmpty else { return }
        userMovedSelection = true
        let current = selectedIndex ?? (delta > 0 ? -1 : entries.count)
        let next = min(max(current + delta, 0), entries.count - 1)
        if extending {
            extendSelection(to: entries[next].id)
        } else {
            selectedID = entries[next].id
        }
    }

    // MARK: Multi-selection

    var isMultiSelecting: Bool { selectedIDs.count > 1 }

    /// Selected history items in list order (snippets and secrets are single-select only).
    var selectedClips: [ClipItem] {
        entries.compactMap { selectedIDs.contains($0.id) ? $0.clip : nil }
    }

    /// Selected secrets in list order (they can be moved between folders together).
    var selectedSecrets: [SecretRef] {
        entries.compactMap { selectedIDs.contains($0.id) ? $0.secret : nil }
    }

    func isSelected(_ entry: PanelEntry) -> Bool { selectedIDs.contains(entry.id) }

    /// Mouse selection following macOS conventions: ⌘ toggles, ⇧ selects a range.
    func click(_ entry: PanelEntry) {
        userMovedSelection = true
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            toggleSelection(entry.id)
        } else if flags.contains(.shift) {
            extendSelection(to: entry.id)
        } else {
            selectedID = entry.id
        }
    }

    func toggleSelection(_ id: String) {
        var ids = selectedIDs
        if ids.contains(id), ids.count > 1 {
            ids.remove(id)
            let focus = id == selectedID ? entries.first { ids.contains($0.id) }?.id : selectedID
            setSelection(ids, focus: focus)
        } else {
            ids.insert(id)
            setSelection(ids, focus: id)
        }
        anchorID = id
    }

    func extendSelection(to id: String) {
        guard let anchor = anchorID ?? selectedID,
              let from = entries.firstIndex(where: { $0.id == anchor }),
              let to = entries.firstIndex(where: { $0.id == id })
        else {
            selectedID = id
            return
        }
        let range = min(from, to)...max(from, to)
        setSelection(Set(entries[range].map(\.id)), focus: id)
    }

    func selectAll() {
        guard let first = entries.first else { return }
        anchorID = first.id
        setSelection(Set(entries.map(\.id)), focus: selectedID ?? first.id)
    }

    private func setSelection(_ ids: Set<String>, focus: String?) {
        adjustingSelection = true
        selectedIDs = ids
        selectedID = focus
        adjustingSelection = false
    }

    func pasteSelection(transform: Transform? = nil) {
        let clips = selectedClips
        guard !clips.isEmpty else { return }
        if clips.count == 1 {
            activate(.clip(clips[0]), transform: transform)
            return
        }
        let target = targetApp
        onClose()
        env.paste.paste(clips, transform: transform, into: target)
    }

    func deleteSelectedClips() {
        let clips = selectedClips
        guard !clips.isEmpty else { return }
        let firstIndex = entries.firstIndex { selectedIDs.contains($0.id) } ?? 0
        for item in clips {
            env.slots.remove(target: .clip(item.id))
            env.store.delete(item)
        }
        refresh()
        if !entries.isEmpty { selectedID = entries[min(firstIndex, entries.count - 1)].id }
        showNotice("Deleted \(clips.count) items")
    }

    /// The filter row as ⇥ walks it: the five chips, with Contacts' Inbox and People and the
    /// shown group's Copies and Saved as their own stops.
    var filterStops: [FilterStop] {
        PanelFilter.chips(showsContacts: env.sync.isSignedIn).flatMap { chip -> [FilterStop] in
            switch chip {
            case .inbox: return [.chip(chip), .people]
            case .groups:
                guard let id = groupFilter ?? rememberedGroupID else { return [.chip(chip)] }
                return [.group(id, saved: false), .group(id, saved: true)]
            default: return [.chip(chip)]
            }
        }
    }

    var currentStop: FilterStop {
        if let groupFilter { return .group(groupFilter, saved: groupShowsSaved) }
        return filter == .inbox && contactsShowPeople ? .people : .chip(filter)
    }

    func select(_ stop: FilterStop) {
        switch stop {
        case .chip(let chip):
            if chip != .groups { groupFilter = nil }
            if chip == .inbox { contactsShowPeople = false }
            filter = chip
        case .people:
            groupFilter = nil
            contactsShowPeople = true
            filter = .inbox
        case .group(let id, let saved):
            groupFilter = id
            groupShowsSaved = saved
        }
    }

    /// ⇥ walks the filter row: Copies → Saved → Auth → Contacts (Inbox, People) → Groups
    /// (the group's Copies, Saved), then around.
    func cycleFilter(forward: Bool) {
        let stops = filterStops
        let current = stops.firstIndex(of: currentStop) ?? 0
        select(stops[(current + (forward ? 1 : stops.count - 1)) % stops.count])
    }

    // MARK: Quick slots

    /// The ⌘-number shown on a row: its assigned slot, or its position if that number is unassigned.
    func shortcutNumber(for entry: PanelEntry, at index: Int) -> (number: Int, isSlot: Bool)? {
        guard let target = entry.slotTarget else { return nil }
        if let slot = env.slots.slot(for: target) { return (slot, true) }
        let position = index + 1
        guard position <= 9, env.slots.target(for: position) == nil else { return nil }
        return (position, false)
    }

    /// ⌘N: the item assigned to slot N, otherwise the Nth row.
    func activateShortcut(_ number: Int, transform: Transform? = nil) {
        if let entry = env.slots.entry(for: number) {
            activate(entry, transform: transform)
        } else if entries.indices.contains(number - 1) {
            activate(entries[number - 1], transform: transform)
        }
    }

    func assignSelection(toSlot number: Int) {
        guard let entry = selectedEntry else { return }
        env.slots.assign(entry, to: number)
        refresh()
        showNotice("Assigned to ⌘\(number)")
    }

    // MARK: Activation

    /// Pastes text made from the selection (a color as RGB, a phone number's digits) into the target app.
    func pasteText(_ text: String) {
        let target = targetApp
        onClose()
        env.paste.paste(text: text, into: target)
    }

    func activate(_ entry: PanelEntry?, transform: Transform? = nil) {
        guard let entry else { return }
        flushEditor?()
        switch entry {
        case .clip(let item):
            let target = targetApp
            let files = pickedFileURLs(for: item)
            onClose()
            if let files {
                env.paste.paste(fileURLs: files, into: target)
            } else {
                env.paste.paste(item, transform: transform, into: target)
            }
        case .snippet(let snippet):
            let fields = SnippetExpander.customFields(in: snippet.body)
            if fields.isEmpty {
                let target = targetApp
                onClose()
                env.pasteSnippet(snippet, values: [:], into: target)
            } else {
                snippetForm = SnippetFormState(snippet: snippet, fields: fields)
                mode = .snippetForm
            }
        case .secret(let ref):
            let target = targetApp
            noteAuthUse(entry)
            onClose()
            env.pasteSecret(ref, into: target)
        case .folder(let folder):
            openFolder(folder)
        case .authenticator(let item):
            if pendingDeleteID == item.id, case .owned(let authenticator) = item {
                confirmDelete(authenticator)
            } else {
                pasteCode(of: item)
            }
        case .authenticatorSuggestion(let account):
            beginAddAuthenticator(from: account)
        case .emailCode(let code, _):
            pasteEmailCode(code)
        }
    }

    // MARK: Authenticators

    /// Fewer seconds than this left: Enter waits for the next code.
    static let nextCodeThreshold: TimeInterval = 3

    /// Pastes the current code into the target app; with under 3 s left, waits for the next one
    /// ("Next code…") so the site doesn't get one that expires on the way.
    func pasteCode(of item: AuthenticatorItem) {
        let now = Date.now
        guard let current = item.code(at: now) else {
            NSSound.beep()
            showNotice("No code right now")
            return
        }
        noteAuthUse(.authenticator(item))
        let target = targetApp
        let left = Double(item.period) - now.timeIntervalSince1970.truncatingRemainder(dividingBy: Double(item.period))
        let nextStart = now.addingTimeInterval(left)
        guard left < Self.nextCodeThreshold, item.code(at: nextStart.addingTimeInterval(0.05)) != nil else {
            onClose()
            env.pasteCode(current, into: target)
            return
        }
        showNotice("Next code…")
        codeWait?.cancel()
        codeWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(left + 0.05))
            guard let self, !Task.isCancelled, let code = item.code(at: .now) else { return }
            self.codeWait = nil
            self.onClose()
            self.env.pasteCode(code, into: target)
        }
    }

    /// An email code into the target app: transient, cleared after 30 s, never in history.
    func pasteEmailCode(_ code: EmailCode) {
        AuthSourceUsage.shared.record(code.authSource)
        let target = targetApp
        onClose()
        env.pasteCode(code.code, into: target)
    }

    func copyEmailCode(_ code: EmailCode) {
        AuthSourceUsage.shared.record(code.authSource)
        env.copyCode(code.code)
        onClose()
    }

    /// Copy Code: transient, cleared after 30 s, never in history.
    func copyCode(of item: AuthenticatorItem) {
        guard let code = item.code(at: .now) else {
            NSSound.beep()
            showNotice("No code right now")
            return
        }
        noteAuthUse(.authenticator(item))
        env.copyCode(code)
        onClose()
    }

    /// The one-off suggestion goes (Esc, or after adding it).
    func dismissSuggestion() {
        env.authenticators.suggestion = nil
        refresh()
    }

    var hasSeenAuthenticatorTip: Bool {
        get { UserDefaults.standard.bool(forKey: "authenticatorTipShown") }
        set { UserDefaults.standard.set(newValue, forKey: "authenticatorTipShown") }
    }

    /// The add form, from a link or QR code (`account`) or empty for typing the setup key.
    func beginAddAuthenticator(from account: OTPAccount? = nil) {
        authenticatorForm = AuthenticatorFormState(purpose: .add(from: account), showsTip: !hasSeenAuthenticatorTip)
        mode = .authenticatorForm
    }

    func beginRename(_ authenticator: Authenticator) {
        selectedID = PanelEntry.authenticator(.owned(authenticator)).id
        authenticatorForm = AuthenticatorFormState(renaming: authenticator)
        mode = .authenticatorForm
    }

    func submitAuthenticatorForm() {
        guard let form = authenticatorForm else { return }
        switch form.purpose {
        case .rename(let id):
            let issuer = form.issuer.trimmingCharacters(in: .whitespacesAndNewlines)
            let account = form.account.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !issuer.isEmpty || !account.isEmpty else {
                form.error = "Enter an issuer or an account."
                return
            }
            env.authenticators.rename(id: id, issuer: issuer, account: account, urls: form.websites)
            resetMode()
            refresh()
            selectedID = "a-o-" + id
            showNotice("Saved")
        case .add:
            switch form.makeAccount() {
            case .failure(let problem):
                form.error = problem.message
                NSSound.beep()
            case .success(let account):
                guard let added = env.authenticators.add(account, urls: form.websites) else {
                    form.error = "Couldn't save to the Keychain."
                    return
                }
                hasSeenAuthenticatorTip = true
                if env.authenticators.suggestion?.secret == account.secret { env.authenticators.suggestion = nil }
                resetMode()
                refresh()
                let id = PanelEntry.authenticator(.owned(added)).id
                if entries.contains(where: { $0.id == id }) { selectedID = id }
                showNotice("Added “\(AuthenticatorItem.owned(added).title)” to Auth")
            }
        }
    }

    /// Show Secret / QR: always asks for Touch ID first.
    func revealSecret(of authenticator: Authenticator) {
        Task {
            let title = AuthenticatorItem.owned(authenticator).title
            guard await env.secrets.authenticateNow(reason: "show the secret of “\(title)”") else { return }
            selectedID = PanelEntry.authenticator(.owned(authenticator)).id
            if mode == .actions { mode = .browse }
            revealedSecretID = authenticator.id
        }
    }

    func hideSecret() { revealedSecretID = nil }

    /// Delete asks inline in the preview first (Return or the button confirms, esc cancels).
    func askToDelete(_ authenticator: Authenticator) {
        selectedID = PanelEntry.authenticator(.owned(authenticator)).id
        if mode == .actions { mode = .browse }
        pendingDeleteID = authenticator.id
    }

    func cancelDelete() { pendingDeleteID = nil }

    func confirmDelete(_ authenticator: Authenticator) {
        let index = selectedIndex
        pendingDeleteID = nil
        revealedSecretID = nil
        env.authenticators.delete(id: authenticator.id)
        env.sync.syncNow()
        refresh()
        if let index, !entries.isEmpty { selectedID = entries[min(index, entries.count - 1)].id }
        showNotice("Deleted “\(AuthenticatorItem.owned(authenticator).title)”")
    }

    /// Share…, People… or Transfer Ownership…: loads who it's shared with, then the list.
    func beginPeople(_ purpose: AuthenticatorPeopleState.Purpose, for authenticator: Authenticator) {
        guard env.sync.isSignedIn else { return }
        selectedID = PanelEntry.authenticator(.owned(authenticator)).id
        let form = AuthenticatorPeopleState(purpose: purpose, authenticator: authenticator)
        peopleForm = form
        mode = .authenticatorPeople
        Task {
            do {
                form.shares = try await env.sync.shares(of: authenticator)
                form.candidates = env.sync.shareCandidates(excluding: Set(form.shares.map(\.uid)))
            } catch {
                form.error = error.localizedDescription
            }
            form.isLoading = false
        }
    }

    func submitPeople(at index: Int? = nil) {
        guard let form = peopleForm, !form.isBusy, !form.isLoading else { return }
        let row = index ?? form.selection
        let title = AuthenticatorItem.owned(form.authenticator).title
        switch form.purpose {
        case .share:
            guard form.candidates.indices.contains(row) else { return }
            let person = form.candidates[row]
            form.isBusy = true
            Task {
                do {
                    try await env.sync.share(form.authenticator, with: person)
                    resetMode()
                    showNotice("Shared “\(title)” with \(person.name). They get codes, never the secret.")
                } catch {
                    form.isBusy = false
                    form.error = error.localizedDescription
                }
            }
        case .people:
            guard form.shares.indices.contains(row) else { return }
            removeShare(form.shares[row])
        case .transfer:
            guard form.shares.indices.contains(row) else { return }
            let share = form.shares[row]
            form.isBusy = true
            Task {
                do {
                    try await env.sync.transfer(form.authenticator, to: share)
                    resetMode()
                    refresh()
                    showNotice("\(share.name) owns “\(title)” now. You'll get codes like everyone else.")
                } catch {
                    form.isBusy = false
                    form.error = error.localizedDescription
                }
            }
        }
    }

    func removeShare(_ share: AuthenticatorShare) {
        guard let form = peopleForm, !form.isBusy else { return }
        form.isBusy = true
        Task {
            do {
                try await env.sync.removeShare(share, of: form.authenticator)
                form.shares.removeAll { $0.uid == share.uid }
                form.selection = min(form.selection, max(0, form.shares.count - 1))
                form.isBusy = false
                let until = Date(syncMillis: share.codesUntil ?? 0)
                showNotice(until > .now
                           ? "Removed. Codes they already have work until \(until.formatted(date: .omitted, time: .shortened))."
                           : "Removed.")
            } catch {
                form.isBusy = false
                form.error = error.localizedDescription
            }
        }
    }

    /// Stops getting codes for one shared with you; it leaves your list.
    func leave(_ shared: SharedAuthenticator) {
        Task {
            do {
                try await env.sync.leave(shared)
                if mode == .actions { mode = .browse }
                refresh()
                showNotice("Left “\(AuthenticatorItem.shared(shared).title)”")
            } catch {
                showNotice(error.localizedDescription)
            }
        }
    }

    func perform(_ action: AuthenticatorAction, on item: AuthenticatorItem) {
        switch (action, item) {
        case (.rename, .owned(let a)): beginRename(a)
        case (.share, .owned(let a)): beginPeople(.share, for: a)
        case (.people, .owned(let a)): beginPeople(.people, for: a)
        case (.transfer, .owned(let a)): beginPeople(.transfer, for: a)
        case (.showSecret, .owned(let a)): revealSecret(of: a)
        case (.delete, .owned(let a)): askToDelete(a)
        case (.leave, .shared(let s)): leave(s)
        default: NSSound.beep()
        }
    }

    func submitSnippetForm() {
        guard let form = snippetForm else { return }
        let target = targetApp
        onClose()
        env.pasteSnippet(form.snippet, values: form.values, into: target)
    }

    func beginLabel(_ entry: PanelEntry) {
        selectedID = entry.id
        switch entry {
        case .clip(let item): labelForm = LabelFormState(target: .clip(item))
        case .secret(let ref): labelForm = LabelFormState(target: .secret(ref))
        case .folder(let folder): labelForm = LabelFormState(target: .folder(folder))
        case .snippet, .authenticator, .authenticatorSuggestion, .emailCode: return
        }
        mode = .label
    }

    func submitLabel() {
        guard let form = labelForm else { return }
        switch form.target {
        case .clip(let item):
            // A quick slot keeps its item even without a label.
            env.store.setLabel(form.text, for: item, keepPinned: env.slots.slot(for: .clip(item.id)) != nil)
            showNotice(item.label == nil ? "Label removed" : "Labelled")
        case .folder(let folder):
            env.store.setLabel(form.text, for: folder)
            showNotice(folder.label == nil ? "Label removed" : "Labelled")
        case .secret(let ref):
            let name = form.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            env.secrets.rename(ref, to: name)
        case .clips(let items):
            for item in items {
                env.store.setLabel(form.text, for: item, keepPinned: env.slots.slot(for: .clip(item.id)) != nil)
            }
            let cleared = form.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            showNotice(cleared ? "Labels removed from \(items.count) items" : "Labelled \(items.count) items")
        }
        let id = selectedID
        resetMode()
        refresh()
        selectedID = id
    }

    // MARK: Label and Folder rows (preview details)

    /// Labelling is offered where the server would accept it: never on selected text from
    /// another app, nor on a group item someone else wrote (unless you own the group). A
    /// contact's items keep their local-only labels.
    func canLabel(_ entry: PanelEntry) -> Bool {
        switch entry {
        case .clip(let item): !item.isTransient && env.sync.canChange(item)
        case .secret(let ref): env.sync.canChange(itemID: ref.id, spaceID: ref.spaceID)
        case .folder(let folder): canChangeFolder(folder)
        case .snippet, .authenticator, .authenticatorSuggestion, .emailCode: false
        }
    }

    /// ⌘L: Label… for the selected row, or one label for every selected clip.
    func beginLabelSelection() {
        if isMultiSelecting {
            let clips = selectedClips.filter { canLabel(.clip($0)) }
            guard !clips.isEmpty else {
                NSSound.beep()
                return
            }
            labelForm = LabelFormState(target: .clips(clips))
            mode = .label
            return
        }
        guard let entry = selectedEntry, canLabel(entry) else {
            NSSound.beep()
            return
        }
        beginLabel(entry)
    }

    /// Where the Folder row's items can go: clips and secrets that may use folders (and that
    /// this account may move, for a group's).
    func canPickFolder(clips: [ClipItem], secrets: [SecretRef]) -> Bool {
        folderMenu(for: clips, secrets: secrets) != nil
    }

    /// The Folder row's path for one item: "Saved › Work › Clients", or nil when it isn't in one.
    func folderPath(of entry: PanelEntry) -> String? {
        let folder: ClipFolder?
        switch entry {
        case .clip(let item): folder = self.folder(of: item)
        case .secret(let ref): folder = self.folder(of: ref)
        default: folder = nil
        }
        return folder.map { "Saved › " + folderPathName($0) }
    }

    /// ⌘⇧M and the Folder row: the inline folder picker for the selection.
    func beginFolderPicker() {
        let (clips, secrets) = isMultiSelecting ? (selectedClips.filter { !$0.isTransient }, selectedSecrets)
            : (selectedEntry?.clip.flatMap { $0.isTransient ? nil : [$0] } ?? [], selectedEntry?.secret.map { [$0] } ?? [])
        guard let menu = folderMenu(for: clips, secrets: secrets) else {
            NSSound.beep()
            return
        }
        folderPicker = FolderPickerState(clips: clips, secrets: secrets, menu: menu,
                                         groupFolders: menu.group.map { env.store.folders(inSpace: $0.id) } ?? [],
                                         personalFolders: env.store.folders(inSpace: nil))
        mode = .folderPicker
    }

    /// A row of the folder picker: into a folder, or (nil) the top level of the items' own Saved.
    func pick(_ row: FolderPickerState.Row) {
        guard let form = folderPicker else { return }
        switch row.kind {
        case .topLevel:
            resetMode()
            let unsaved = form.clips.filter { !$0.isPinned && env.sync.canChange($0) }
            if !unsaved.isEmpty { env.store.addToSaved(unsaved) }
            let inFolders = (form.clips.filter { folder(of: $0) != nil }, form.secrets.filter { folder(of: $0) != nil })
            if !inFolders.0.isEmpty || !inFolders.1.isEmpty {
                removeFromFolder(inFolders.0, secrets: inFolders.1)
            } else {
                refresh()
                showNotice(unsaved.isEmpty ? "Already at the top level" : "Added to Saved")
            }
        case .folder(let folder):
            resetMode()
            place(form.clips, secrets: form.secrets, in: folder)
        case .newFolder(let parent, let personal):
            resetMode()
            beginNewFolder(moving: form.clips, secrets: form.secrets, personal: personal, parent: parent)
        }
    }

    // MARK: Add Items (Saved header)

    /// The inline picker of recent history to save here (into the open folder, if any).
    func beginAddItems() {
        guard isSavedView else { return }
        let space = savedSpaceID
        guard env.sync.canSend(to: space) else { return refuseSend(to: space) }
        let candidates = env.store.items(inSpace: space).filter { !$0.isPinned && env.sync.canChange($0) }
        addItemsForm = AddItemsState(candidates: candidates, folder: openFolder)
        mode = .addItems
    }

    func submitAddItems() {
        guard let form = addItemsForm else { return }
        let chosen = form.candidates.filter { form.checked.contains($0.id) }
        guard !chosen.isEmpty else {
            NSSound.beep()
            return
        }
        resetMode()
        if let contact = form.contact {
            sendToContacts([contact], entries: chosen.map(PanelEntry.clip))
            return
        }
        env.store.addToSaved(chosen)
        if let folder = form.folder { env.store.move(chosen, to: folder) }
        refresh()
        let place = form.folder.map(\.name) ?? "Saved"
        showNotice(chosen.count == 1 ? "Added 1 item to \(place)" : "Added \(chosen.count) items to \(place)")
    }

    func beginEditSecret(_ ref: SecretRef) {
        selectedID = PanelEntry.secret(ref).id
        Task {
            guard let value = await env.secrets.reveal(ref, reason: "edit “\(ref.name)”") else { return }
            showEditSecret(ref, value: value)
        }
    }

    /// Opens the edit form once the value has been unlocked.
    func showEditSecret(_ ref: SecretRef, value: String) {
        editSecretForm = EditSecretState(ref: ref, value: value, notes: env.secrets.notes(of: ref))
        mode = .editSecret
    }

    /// Auth's + menu: New Password… / New Secret…, in the right pane.
    func beginNewPassword() {
        editSecretForm = EditSecretState(new: .password)
        mode = .editSecret
    }

    func beginNewSecret() {
        editSecretForm = EditSecretState(new: .secret)
        mode = .editSecret
    }

    func submitEditSecret() {
        guard let form = editSecretForm else { return }
        let name = form.resolvedName
        guard form.canSave else {
            form.error = !form.value.isEmpty ? "Enter a name." : form.kind == .password ? "Enter a password." : "Enter a value."
            return
        }
        let username = SecretExtras.cleanUsername(form.username)
        let notes = form.notes.isEmpty ? nil : form.notes
        let savedID: String
        if let ref = form.ref {
            let notesChanged = form.notes != form.originalNotes
            env.secrets.update(ref, name: name != ref.name ? name : nil,
                               value: form.value != form.originalValue ? form.value : nil,
                               username: .some(username), urls: form.cleanSites,
                               notes: notesChanged ? .some(notes) : nil)
            savedID = ref.id
        } else {
            guard let added = env.secrets.add(name: name, value: form.value, username: username, urls: form.cleanSites,
                                              notes: notes) else {
                form.error = "Couldn't save to the Keychain."
                return
            }
            savedID = added.id
        }
        resetMode()
        refresh()
        let id = "k-" + savedID
        if entries.contains(where: { $0.id == id }) { selectedID = id }
        showNotice("Saved “\(name)”")
    }

    func beginSaveSecret(_ item: ClipItem) {
        selectedID = PanelEntry.clip(item).id
        // Labelled already: that's its name, so there's nothing to ask.
        if let label = item.label?.trimmingCharacters(in: .whitespaces), !label.isEmpty {
            saveAsSecret(item, name: label)
            return
        }
        saveSecretForm = SaveSecretState(item: item)
        mode = .saveSecret
    }

    func submitSaveSecret() {
        guard let form = saveSecretForm else { return }
        saveAsSecret(form.item, name: form.name.trimmingCharacters(in: .whitespaces))
    }

    private func saveAsSecret(_ item: ClipItem, name: String) {
        // A personal item's secret stays in its folder; a group item's becomes a personal secret, as before.
        let folderID = item.spaceID == nil ? item.folderID : nil
        guard !name.isEmpty, env.secrets.add(name: name, value: item.text, folderID: folderID) != nil else {
            showNotice("Couldn't save to the Keychain")
            return
        }
        if !item.isTransient { env.store.delete(item) }
        resetMode()
        refresh()
        showNotice("Saved “\(name)” to Secrets and removed it from history")
    }

    // MARK: Share to group

    /// Share to Group is offered while there's a group this account may send to.
    var canShareToGroup: Bool { env.sync.isSignedIn && !shareGroups.isEmpty }

    /// Where items can be shared: groups with Send.
    var shareGroups: [SyncGroup] { env.sync.sendableGroups }

    /// Where a secret can be shared: groups with Send and Secrets, other than its own.
    func shareGroups(for ref: SecretRef) -> [SyncGroup] {
        shareGroups.filter { $0.canSeeSecrets && $0.id != ref.spaceID }
    }

    /// Whether the open view (a group's list or Saved) takes new things from this account.
    var canAddHere: Bool { env.sync.canSend(to: isSavedView ? savedSpaceID : groupFilter) }

    /// "You can't send to ‹Group›", for a write the group refuses.
    func refuseSend(to spaceID: String?) {
        NSSound.beep()
        showNotice("You can't send to \(env.sync.groupName(for: spaceID) ?? "this group")")
    }

    func beginShare(_ items: [ClipItem]) {
        guard canShareToGroup, !items.isEmpty else { return }
        shareForm = ShareGroupState(items: items, groups: shareGroups, defaultGroupID: env.prefs.syncDefaultGroupID,
                                    foldersByGroup: groupFolders)
        mode = .shareToGroup
    }

    /// Every group's folders, for the share form's destination.
    private var groupFolders: [String: [ClipFolder]] {
        Dictionary(shareGroups.map { ($0.id, treeOrderedFolders(inSpace: $0.id)) }, uniquingKeysWith: { first, _ in first })
    }

    func submitShare() {
        guard let form = shareForm, let group = form.selectedGroup else { return }
        let destination = form.destination
        resetMode()
        if let ref = form.secret {
            Task {
                guard let value = await env.secrets.reveal(ref, reason: "share “\(ref.name)” with \(group.name)") else { return }
                shareSecret(ref, value: value, to: group, folder: destination)
            }
        } else if let folder = form.folder {
            share(folder, to: group, parent: destination)
        } else {
            share(form.items, to: group, folder: destination)
        }
    }

    /// Share to Group… on a personal folder: picks the group, then copies the folder and its clips.
    func beginShareFolder(_ folder: ClipFolder) {
        guard canShareToGroup, folder.spaceID == nil else { return }
        selectedID = PanelEntry.folder(folder).id
        shareForm = ShareGroupState(items: subtreeItems(of: folder), folder: folder, groups: shareGroups,
                                    defaultGroupID: env.prefs.syncDefaultGroupID, foldersByGroup: groupFolders)
        mode = .shareToGroup
    }

    /// The saved clips in a folder and every folder below it.
    func subtreeItems(of folder: ClipFolder) -> [ClipItem] {
        let ids = folderTree(of: folder).subtree(of: folder.id)
        return ids.compactMap(env.store.folder(withID:)).flatMap(env.store.items(inFolder:))
    }

    /// Copies a personal folder with its whole subtree (new ids, same names, labels and
    /// structure), its clips and its secrets into the group, in `parent` (one of the group's
    /// folders) or at its top level. Yours stays as it is; later changes don't follow. Secrets
    /// are read after one Touch ID.
    func share(_ folder: ClipFolder, to group: SyncGroup, parent: ClipFolder? = nil) {
        guard env.sync.canSend(to: group.id) else { return refuseSend(to: group.id) }
        let items = subtreeItems(of: folder)
        if let problem = items.lazy.compactMap(SyncEngine.groupShareProblem).first {
            refuseGroupShare(problem)
            return
        }
        let folderIDs = folderTree(of: folder).subtree(of: folder.id)
        // A group whose secrets this account can't see takes the folder without them.
        let secrets = !env.sync.canSeeSecrets(in: group.id) ? [] : env.secrets.secrets.filter {
            $0.spaceID == folder.spaceID && $0.folderID.map(folderIDs.contains) == true
        }
        let finish = { [self] (values: [(SecretRef, String)]) in
            var copies: [UUID: UUID] = [:]
            env.store.shareCopy(of: folder, toSpace: group.id, parent: parent.flatMap { $0.spaceID == group.id ? $0 : nil }) { original, copy in
                copies[original] = copy.id
            }
            for (ref, value) in values {
                env.secrets.add(name: ref.name, value: value, spaceID: group.id, folderID: ref.folderID.flatMap { copies[$0] })
            }
            env.sync.syncNow()
            refresh()
            showNotice("Shared “\(folder.name)” to \(group.name)")
        }
        guard !secrets.isEmpty else {
            finish([])
            return
        }
        Task {
            guard await env.secrets.authenticate(reason: "share “\(folder.name)” with \(group.name)") else { return }
            finish(secrets.compactMap { ref in SecretVault.value(id: ref.id).map { (ref, $0) } })
        }
    }

    func beginShareSecret(_ ref: SecretRef) {
        let groups = shareGroups(for: ref)
        guard canShareToGroup, !groups.isEmpty else { return }
        selectedID = PanelEntry.secret(ref).id
        shareForm = ShareGroupState(secret: ref, groups: groups, defaultGroupID: env.prefs.syncDefaultGroupID,
                                    foldersByGroup: groupFolders)
        mode = .shareToGroup
    }

    /// Stores a copy of the secret in the group's space (in one of its folders, if given). Yours
    /// stays as it is; later edits don't follow.
    func shareSecret(_ ref: SecretRef, value: String, to group: SyncGroup, folder: ClipFolder? = nil) {
        guard env.sync.canSend(to: group.id), env.sync.canSeeSecrets(in: group.id) else { return refuseSend(to: group.id) }
        let folder = folder?.spaceID == group.id ? folder : nil
        let existing = env.secrets.secrets.first {
            $0.spaceID == group.id && $0.name == ref.name && SecretVault.value(id: $0.id) == value
        }
        let already = existing != nil
        if let existing, let folder, existing.folderID != folder.id, env.sync.canChange(itemID: existing.id, spaceID: group.id) {
            env.secrets.setFolder(folder.id, for: [existing])
            env.sync.syncNow()
        }
        if !already {
            guard env.secrets.add(name: ref.name, value: value, spaceID: group.id, folderID: folder?.id) != nil else {
                showNotice("Couldn't save to the Keychain")
                return
            }
            env.sync.syncNow()
            refresh()
        }
        showNotice(already ? "“\(ref.name)” is already in \(group.name)" : "Shared “\(ref.name)” with \(group.name)")
    }

    /// Copies items into a group's space with new ids (selected text from another app is stored
    /// there); with `folder` (one of the group's), the copies go in it.
    func share(_ items: [ClipItem], to group: SyncGroup, folder: ClipFolder? = nil) {
        guard env.sync.canSend(to: group.id) else { return refuseSend(to: group.id) }
        if let problem = items.lazy.compactMap(SyncEngine.groupShareProblem).first {
            refuseGroupShare(problem)
            return
        }
        let copies = copy(items, intoSpace: group.id)
        if let folder, folder.spaceID == group.id {
            // Copies that were already in the group (same content) only move if this account may change them.
            env.store.move(copies.filter { env.sync.canChange($0) }, to: folder)
        }
        if isSelectionMode {
            onClose()
            HUD.show("Sent to \(group.name)", symbol: "person.2.fill")
        } else {
            refresh()
            showNotice(items.count == 1 ? "Shared to \(group.name)" : "Shared \(items.count) items to \(group.name)")
        }
    }

    /// Stores copies in a group's or contact's space; the next sync uploads them. A contact gets
    /// them without this user's labels. Returns the copies.
    @discardableResult
    private func copy(_ items: [ClipItem], intoSpace spaceID: String, keepLabel: Bool = true) -> [ClipItem] {
        var copies: [ClipItem] = []
        for item in items {
            if item.isTransient {
                copies.append(env.store.ingest(.text(item.text, source: item.source), spaceID: spaceID))
            } else if item.spaceID != spaceID {
                copies.append(env.store.shareCopy(of: item, toSpace: spaceID, keepLabel: keepLabel))
            }
        }
        env.sync.syncNow()
        return copies
    }

    // MARK: Send to contact

    /// Contacts the selection can be sent to (established ones: both people are in the space).
    var sendableContacts: [SyncContact] { env.sync.isSignedIn ? env.sync.contacts : [] }

    /// Send to Contact… and the three most recent contacts as direct "Send to ‹name›" rows.
    /// Never for what a contact sent you, or into the contact's own space.
    func contactSendActions(excludingSpace spaceID: String? = nil) -> [PanelAction] {
        let contacts = rankedContacts.filter { $0.id != spaceID }
        guard !contacts.isEmpty else { return [] }
        return [.chooseContact] + contacts.prefix(3).map(PanelAction.sendToContact)
    }

    /// Contacts, the ones you last exchanged something with first.
    var rankedContacts: [SyncContact] { PeopleList.ranked(sendableContacts, lastExchange: lastExchange) }

    /// Puts copies of the clips and secrets in each contact's space: they show up in the contact's
    /// Inbox. Same limits as sharing to a group; secrets were unlocked first.
    func deliver(clips: [ClipItem], secrets: [(ref: SecretRef, value: String)], to contacts: [SyncContact]) {
        guard !contacts.isEmpty, !clips.isEmpty || !secrets.isEmpty else { return }
        if let problem = clips.lazy.compactMap(SyncEngine.groupShareProblem).first {
            refuseGroupShare(problem.replacingOccurrences(of: "Groups take", with: "Sync takes"))
            return
        }
        for contact in contacts {
            copy(clips, intoSpace: contact.id, keepLabel: false)
            for secret in secrets where secret.ref.spaceID != contact.id {
                let already = env.secrets.secrets.contains {
                    $0.spaceID == contact.id && $0.name == secret.ref.name && SecretVault.value(id: $0.id) == secret.value
                }
                if !already { _ = env.secrets.add(name: secret.ref.name, value: secret.value, spaceID: contact.id) }
            }
        }
        env.sync.syncNow()
        let text = Self.sentText(to: contacts.map(\.name))
        if isSelectionMode {
            onClose()
            HUD.show(text, symbol: "paperplane.fill")
        } else {
            if mode == .actions || mode == .contactPicker { resetMode() }
            refresh()
            showNotice(text)
        }
    }

    /// "Sent to Sam", "Sent to Sam and Alex", "Sent to 3 contacts".
    nonisolated static func sentText(to names: [String]) -> String {
        switch names.count {
        case 1: "Sent to \(names[0])"
        case 2: "Sent to \(names[0]) and \(names[1])"
        default: "Sent to \(names.count) contacts"
        }
    }

    /// Nothing is shared; the reason shows big enough not to be missed.
    private func refuseGroupShare(_ problem: String) {
        NSSound.beep()
        if mode == .actions || mode == .shareToGroup { mode = .browse }
        HUD.show(problem, symbol: "exclamationmark.triangle.fill", duration: .seconds(3.5))
        showNotice("Not shared")
    }

    // MARK: Send to device

    func send(_ item: ClipItem, to device: DeviceTarget) {
        if let problem = SyncEngine.groupShareProblem(item) {
            refuseGroupShare(problem.replacingOccurrences(of: "Groups take", with: "Sync takes"))
            return
        }
        env.sync.sendToDevice(item, deviceId: device.id)
        if mode == .actions { mode = .browse }
        showNotice("Sent to \(device.name)")
    }

    // MARK: Save to folder

    /// True while the folder picker is up, so the panel doesn't close when it loses focus.
    @ObservationIgnored private(set) var isChoosingFolder = false
    /// Set by the controller: makes the panel key again (after the folder picker).
    @ObservationIgnored var onRefocus: () -> Void = {}

    /// The clips a context-menu action on `entry` applies to: the whole selection if it's part of one.
    func clipsForContextAction(on entry: PanelEntry) -> [ClipItem] {
        guard let item = entry.clip else { return [] }
        return isMultiSelecting && isSelected(entry) ? selectedClips : [item]
    }

    /// The clips and secrets a context-menu action on `entry` applies to: the whole selection if
    /// it's part of one.
    func itemsForContextAction(on entry: PanelEntry) -> (clips: [ClipItem], secrets: [SecretRef]) {
        if isMultiSelecting && isSelected(entry) { return (selectedClips.filter { !$0.isTransient }, selectedSecrets) }
        return (entry.clip.flatMap { $0.isTransient ? nil : [$0] } ?? [], entry.secret.map { [$0] } ?? [])
    }

    /// Writes the items into `folder` as files and says how it went. The panel stays open, like Copy.
    func save(_ items: [ClipItem], to folder: URL) {
        guard !items.isEmpty else { return }
        if mode == .actions { mode = .browse }
        let outcome = FolderSaver(blobs: env.blobs).save(items, to: folder) { self.pickedFileURLs(for: $0) ?? $0.fileURLs }
        let name = FileManager.default.displayName(atPath: folder.path)
        let saved = outcome.saved.count
        if outcome.failures.isEmpty {
            showNotice(saved == 1 ? "Saved to \(name)" : "Saved \(saved) files to \(name)")
        } else if saved == 0 {
            NSSound.beep()
            showNotice("Not saved: \(outcome.failures[0])")
        } else {
            showNotice("Saved \(saved) to \(name) · \(outcome.failures.count) failed: \(outcome.failures[0])")
        }
    }

    /// Asks for a folder first (starting in the usual save folder).
    func saveChoosingFolder(_ items: [ClipItem]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = env.prefs.saveFolder
        panel.prompt = "Save"
        panel.message = items.count == 1 ? "Choose where to save this item" : "Choose where to save \(items.count) items"
        isChoosingFolder = true
        NSApp.activate()
        let response = panel.runModal()
        isChoosingFolder = false
        onRefocus()
        guard response == .OK, let folder = panel.url else { return }
        save(items, to: folder)
    }

    // MARK: Quick Look

    /// Writes text items out for Quick Look and finds the files of the rest.
    @ObservationIgnored var quickLookFiles: QuickLookFiles
    /// Set by the controller: whether the Quick Look panel is up.
    @ObservationIgnored var isQuickLookOpen: () -> Bool = { false }
    /// Set by the controller: shows (true) or closes (false) the Quick Look panel.
    @ObservationIgnored var onQuickLook: (Bool) -> Void = { _ in }
    /// Set by the controller: the selection (or the files picked in it) changed, so an open
    /// Quick Look panel follows it.
    @ObservationIgnored var onQuickLookItemsChanged: () -> Void = {}

    /// Selected entries in list order; snippets and secrets are never previewed.
    private var quickLookEntries: [PanelEntry] {
        if isMultiSelecting { return selectedClips.map(PanelEntry.clip) }
        return selectedEntry.map { [$0] } ?? []
    }

    /// Something in the selection can be shown in Quick Look (⌘Y).
    var canQuickLook: Bool {
        quickLookEntries.contains(where: quickLookFiles.canPreview)
    }

    /// What Quick Look shows for the selection: every selected item, and only the picked files
    /// of a multi-file item. Text, links and colours (a selection from another app too) are
    /// written to temporary files.
    func quickLookURLs() -> [URL] {
        quickLookFiles.urls(for: quickLookEntries) { self.pickedFileURLs(for: $0) ?? $0.fileURLs }
    }

    /// ⌘Y: opens Quick Look on the selection, or closes it.
    func toggleQuickLook() {
        if isQuickLookOpen() {
            onQuickLook(false)
        } else if canQuickLook {
            if mode == .actions { mode = .browse }
            onQuickLook(true)
        } else {
            NSSound.beep()
        }
    }

    /// The row menu's Quick Look: previews the row (with the rest of the selection, if it's part of one).
    func quickLook(_ entry: PanelEntry) {
        if !isSelected(entry) { selectedID = entry.id }
        if !isQuickLookOpen() { toggleQuickLook() }
    }

    // MARK: Drag and drop

    /// Called after a drop was accepted, so the panel takes keyboard focus back (a drag from
    /// Finder makes Finder the key app on the way in).
    @ObservationIgnored var onDropFinished: () -> Void = {}

    /// A history item dragged onto a group chip: share it (with the rest of the selection, if it
    /// was part of one) to that group.
    @discardableResult
    func dropClip(id: UUID, onGroup groupID: String) -> Bool {
        guard env.sync.isSignedIn, let group = env.sync.groups.first(where: { $0.id == groupID }),
              let item = env.store.item(withID: id)
        else { return false }
        guard group.canSend else {
            onDropFinished()
            refuseSend(to: group.id)
            return false
        }
        let dragged = PanelEntry.clip(item).id
        let items = isMultiSelecting && selectedIDs.contains(dragged) ? selectedClips : [item]
        let toShare = items.filter { $0.spaceID != group.id }
        onDropFinished()
        guard !toShare.isEmpty else {
            showNotice("Already in \(group.name)")
            return true
        }
        share(toShare, to: group)
        return true
    }

    /// The dragged row's clips and secrets, with the rest of the selection if it was part of one.
    private func dragged(_ reference: PanelDrag.Reference) -> (clips: [ClipItem], secrets: [SecretRef]) {
        let entry: PanelEntry
        switch reference {
        case .clip(let id):
            guard let item = env.store.item(withID: id) else { return ([], []) }
            entry = .clip(item)
        case .secret(let id):
            guard let ref = env.secrets.secrets.first(where: { $0.id == id }) else { return ([], []) }
            entry = .secret(ref)
        case .folder:
            return ([], [])
        }
        if isMultiSelecting && selectedIDs.contains(entry.id) { return (selectedClips, selectedSecrets) }
        return (entry.clip.map { [$0] } ?? [], entry.secret.map { [$0] } ?? [])
    }

    /// Clips dragged onto a folder row: they move in (only clips of the folder's own space).
    @discardableResult
    func dropClip(id: UUID, onFolder folderID: UUID) -> Bool {
        drop(.clip(id), onFolder: folderID)
    }

    /// Clips and secrets dragged onto a folder row: they move in.
    @discardableResult
    func drop(_ reference: PanelDrag.Reference, onFolder folderID: UUID) -> Bool {
        guard let folder = env.store.folder(withID: folderID) else { return false }
        onDropFinished()
        if case .folder(let moving) = reference {
            guard let source = env.store.folder(withID: moving) else { return false }
            return moveFolder(source, under: folder)
        }
        let (clips, secrets) = dragged(reference)
        place(clips, secrets: secrets, in: folder)
        return true
    }

    /// Clips dragged onto the "Saved" breadcrumb from inside a folder: out to the root.
    @discardableResult
    func dropClipOnSavedRoot(id: UUID) -> Bool {
        dropOnSavedRoot(.clip(id))
    }

    @discardableResult
    func dropOnSavedRoot(_ reference: PanelDrag.Reference) -> Bool {
        if case .folder(let moving) = reference {
            onDropFinished()
            guard let source = env.store.folder(withID: moving) else { return false }
            return moveFolder(source, under: nil)
        }
        let (clips, secrets) = dragged(reference)
        onDropFinished()
        let inFolders = (clips.filter { $0.folderID != nil }, secrets.filter { $0.folderID != nil })
        guard !inFolders.0.isEmpty || !inFolders.1.isEmpty else { return false }
        removeFromFolder(inFolders.0, secrets: inFolders.1)
        return true
    }

    /// A secret dragged onto a group chip: shared there after Touch ID.
    @discardableResult
    func dropSecret(id: String, onGroup groupID: String) -> Bool {
        guard env.sync.isSignedIn, let group = env.sync.groups.first(where: { $0.id == groupID }),
              let ref = env.secrets.secrets.first(where: { $0.id == id })
        else { return false }
        guard group.canSend, group.canSeeSecrets else {
            onDropFinished()
            refuseSend(to: group.id)
            return false
        }
        onDropFinished()
        guard ref.spaceID != group.id else {
            showNotice("Already in \(group.name)")
            return true
        }
        Task {
            guard let value = await env.secrets.reveal(ref, reason: "share “\(ref.name)” with \(group.name)") else { return }
            shareSecret(ref, value: value, to: group)
        }
        return true
    }

    /// Files dragged in from Finder. On a group chip they're shared to that group; on the list
    /// they're added to history (or to the group being shown).
    func dropFiles(_ urls: [URL], onGroup groupID: String? = nil) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        let target = groupID ?? groupFilter
        let group = target.flatMap { id in env.sync.groups.first { $0.id == id } }
        if target != nil && group == nil { return }
        onDropFinished()
        if let group, !group.canSend { return refuseSend(to: group.id) }
        if group != nil, let problem = SyncEngine.groupShareProblem(fileURLs: files) {
            refuseGroupShare(problem)
            return
        }
        let raw = RawCapture(kind: .file, fileURLs: files)
        Task {
            guard let capture = await CaptureProcessor.process(raw, blobs: env.blobs) else { return }
            env.store.ingest(capture, spaceID: group?.id)
            env.sync.reportActivity()
            let what = files.count == 1 ? "“\(files[0].lastPathComponent)”" : "\(files.count) files"
            if let group {
                env.sync.syncNow()
                showNotice(groupID == nil ? "Added \(what) to \(group.name)" : "Shared \(what) to \(group.name)")
            } else {
                if filter != .copies { filter = .copies }
                showNotice("Added \(what) to history")
            }
            refresh(resetSelection: true)
        }
    }

    // MARK: Action menu

    func openActions() {
        guard selectedEntry != nil || isMultiSelecting else { return }
        actionQuery = ""
        actionSelection = 0
        mode = .actions
    }

    var aiName: String { env.isAIReady ? env.prefs.aiProvider.shortName : "AI" }

    /// AI rows for the action menu: the real actions once a provider is set up, otherwise a
    /// single "Set Up AI…" so nothing pretends to be ready.
    private var aiActions: [PanelAction] {
        guard env.isAIReady else { return [.setUpAI] }
        return AIAction.builtIn.map(PanelAction.ai) + env.prefs.customPrompts.map { PanelAction.ai(.custom($0)) }
    }

    var availableActions: [PanelAction] {
        if isMultiSelecting {
            let clips = selectedClips
            let secrets = selectedSecrets
            // With secrets in it, a selection only moves between folders.
            if !secrets.isEmpty { return savedActions(for: clips, secrets: secrets) }
            guard !clips.isEmpty else { return [] }
            var actions: [PanelAction] = [.paste]
            if clips.allSatisfy(\.kind.isTextual) {
                actions.append(.pastePlain)
                actions.append(.copy)
                actions += Transform.allCases.filter { $0 != .plainText }.map(PanelAction.transform)
            } else {
                actions.append(.copy)
            }
            if canQuickLook { actions.append(.quickLook) }
            actions += savedActions(for: clips)
            if canShareToGroup { actions.append(.shareToGroup) }
            if clips.contains(where: canSendToContact) { actions += contactSendActions() }
            return actions + [.saveToFolder, .saveToChosenFolder, .delete]
        }
        guard let entry = selectedEntry else { return [] }
        if let item = entry.authenticator {
            return PanelAction.authenticatorActions(for: item, signedIn: env.sync.isSignedIn, shareCount: shareCount(of: item))
        }
        if entry.isSuggestion { return [] }
        if case .folder(let folder) = entry {
            var actions: [PanelAction] = [.openFolder, .renameFolder]
            if canLabel(entry) { actions.append(.setLabel) }
            if canChangeFolder(folder) {
                if FolderTree(env.store.folders(inSpace: folder.spaceID)).canCreate(in: folder.id) { actions.append(.newSubfolder) }
                actions += folderTargets(forMoving: folder).map(PanelAction.moveFolder)
                if folderTree(of: folder).parent(of: folder.id) != nil { actions.append(.moveFolderToTop) }
            }
            if folder.spaceID == nil && canShareToGroup { actions.append(.shareToGroup) }
            if !sendableContacts.isEmpty { actions.append(.chooseContact) }
            return actions + [.deleteFolder]
        }
        var actions: [PanelAction] = [.paste]
        switch entry {
        case .clip(let item) where item.isTransient:
            // Selected text from another app: only transform it, ask AI, or keep it.
            actions = [.copy]
            actions += aiActions
            actions += Transform.allCases.filter { $0 != .plainText }.map(PanelAction.transform)
            actions.append(.saveAsSecret)
            if canShareToGroup { actions.append(.shareToGroup) }
            return actions + contactSendActions()
        case .clip(let item):
            if item.kind.isTextual { actions.append(.pastePlain) }
            actions.append(.copy)
            if canQuickLook { actions.append(.quickLook) }
            if item.kind.isTextual {
                actions += Transform.allCases.filter { $0 != .plainText }.map(PanelAction.transform)
                actions += aiActions
                actions.append(.saveAsSecret)
            } else if item.kind == .image && !item.isConcealed {
                actions += aiActions.filter { if case .ai(let ai) = $0 { ai.worksOnImages } else { true } }
            }
            actions += savedActions(for: [item])
            if canShareToGroup { actions.append(.shareToGroup) }
            actions += PanelAction.sendToDeviceActions(for: item, multiSelecting: false, targets: DeviceTarget.others(in: env.sync))
            if canSendToContact(item) { actions += contactSendActions(excludingSpace: item.spaceID) }
            actions += [.saveToFolder, .saveToChosenFolder]
        case .snippet, .folder, .authenticator, .authenticatorSuggestion, .emailCode:
            break
        case .secret(let ref):
            actions.append(.copy)
            if canLabel(entry) { actions.append(.setLabel) }
            actions += savedActions(for: [], secrets: [ref])
            if canShareToGroup && !shareGroups(for: ref).isEmpty { actions.append(.shareToGroup) }
            if canSendToContact(ref) { actions += contactSendActions(excludingSpace: ref.spaceID) }
        }
        if let target = entry.slotTarget, let slot = env.slots.slot(for: target) {
            actions.append(.clearSlot(slot))
        }
        if entry.clip != nil || { if case .secret = entry { return true } else { return false } }() {
            actions.append(.delete)
        }
        return actions
    }

    /// Save… for clips; for secrets Move to ‹folder›, New Folder… and Remove from Folder. Then
    /// Remove from Folder and Remove from Saved, as they apply.
    private func savedActions(for clips: [ClipItem], secrets: [SecretRef] = []) -> [PanelAction] {
        guard !clips.isEmpty || !secrets.isEmpty, clips.allSatisfy({ !$0.isTransient }) else { return [] }
        var actions: [PanelAction] = []
        let changeable = clips.allSatisfy(env.sync.canChange)
        if secrets.isEmpty {
            // Clips: one Save… (label and destination), then the ways out of Saved.
            actions.append(.save)
            if changeable && clips.contains(where: { env.store.folder(of: $0) != nil }) { actions.append(.removeFromFolder) }
            if changeable && clips.contains(where: { $0.isPinned && $0.label == nil }) { actions.append(.removeFromLabelled) }
            return actions
        }
        if clips.contains(where: { !$0.isPinned }) && changeable { actions.append(.addToSaved) }
        // The server refuses changes to another member's group item: keep a copy of your own instead.
        if !changeable { actions.append(.saveCopy) }
        if let menu = folderMenu(for: clips, secrets: secrets) {
            if let group = menu.group {
                actions += group.folders.map(PanelAction.moveToFolder)
                actions.append(.moveToNewFolder)
            }
            actions += menu.personal.map(PanelAction.moveToFolder)
            actions.append(menu.copiesToPersonal ? .copyToNewFolder : .moveToNewFolder)
        }
        let mayChangeAll = changeable && secrets.allSatisfy { env.sync.canChange(itemID: $0.id, spaceID: $0.spaceID) }
        if mayChangeAll && (clips.contains { env.store.folder(of: $0) != nil } || secrets.contains { folder(of: $0) != nil }) {
            actions.append(.removeFromFolder)
        }
        // A label keeps an item saved; it's released by removing the label.
        if changeable && clips.contains(where: { $0.isPinned && $0.label == nil }) { actions.append(.removeFromLabelled) }
        return actions
    }

    /// How many people an authenticator you own is shared with: 0 before it's on the server, nil
    /// while not known yet.
    func shareCount(of item: AuthenticatorItem) -> Int? {
        guard let authenticator = item.owned else { return nil }
        guard let space = authenticator.spaceID else { return 0 }
        return env.authenticators.shareCounts[space]
    }

    /// An action's title for the current selection.
    func title(for action: PanelAction) -> String {
        if selectedEntry?.authenticator != nil && !isMultiSelecting {
            if action == .paste { return "Paste Code" }
            if action == .copy { return "Copy Code" }
        }
        if let count = pickedFileCount {
            switch action {
            case .paste: return "Paste \(count.picked) of \(count.total) Files"
            case .copy: return "Copy \(count.picked) of \(count.total) Files"
            default: break
            }
        }
        if action == .delete, isRemovingFromGroup { return "Remove from Group" }
        if action == .save, !isMultiSelecting, let item = selectedEntry?.clip, isSaved(item) { return "Edit Saved…" }
        if case .moveToFolder(let folder) = action, folder.spaceID == nil, selectionHasGroupItems {
            return "Save a Copy to \(folderPathName(folder))"
        }
        if case .moveToFolder(let folder) = action, let space = folder.spaceID, let name = env.sync.groupName(for: space) {
            return "Move to \(folderPathName(folder)) in \(name)"
        }
        if case .moveToFolder(let folder) = action { return "Move to \(folderPathName(folder))" }
        if case .moveFolder(let folder) = action { return "Move to \(folderPathName(folder))" }
        if action == .moveToNewFolder, let space = (selectedClips.first?.spaceID ?? selectedSecrets.first?.spaceID),
           let name = env.sync.groupName(for: space) {
            return "Move to New Folder in \(name)…"
        }
        return action.title(folderName: env.prefs.saveFolderName)
    }

    /// The selection holds items of a group (moving them to a personal folder saves copies).
    private var selectionHasGroupItems: Bool {
        let rows = isMultiSelecting ? entries.filter { selectedIDs.contains($0.id) } : selectedEntry.map { [$0] } ?? []
        return rows.contains { isGroupSpace($0.clip?.spaceID ?? $0.secret?.spaceID) }
    }

    /// Delete on group items removes them for everyone in the group.
    var isRemovingFromGroup: Bool {
        let clips = isMultiSelecting ? selectedClips : selectedEntry?.clip.map { [$0] } ?? []
        return !clips.isEmpty && clips.allSatisfy { isGroupSpace($0.spaceID) }
    }

    var filteredActions: [PanelAction] {
        let q = actionQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return availableActions }
        var matches = availableActions
            .compactMap { action in
                FuzzyMatcher.score(query: q, in: title(for: action) + " " + action.section(aiName: aiName))
                    .map { (action, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        // Anything typed can also be sent as a question or instruction about the selected item.
        if !isMultiSelecting, let clip = selectedEntry?.clip, !clip.isConcealed, clip.kind.isTextual || clip.kind == .image {
            if env.isAIReady {
                // A sentence or question is meant for the AI, not a filter: offer it first.
                let looksLikeQuestion = q.contains(" ") || q.hasSuffix("?")
                if looksLikeQuestion { matches.insert(.ai(.instruction(q)), at: 0) } else { matches.append(.ai(.instruction(q))) }
            } else if !matches.contains(.setUpAI) {
                matches.append(.setUpAI)
            }
        }
        return matches
    }

    func perform(_ action: PanelAction) {
        if isMultiSelecting {
            performOnSelection(action)
            return
        }
        guard let entry = selectedEntry else { return }
        if let item = entry.authenticator {
            switch action {
            case .paste:
                mode = .browse
                pasteCode(of: item)
            case .copy: copyCode(of: item)
            case .authenticator(let action): perform(action, on: item)
            default: break
            }
            return
        }
        switch action {
        case .paste:
            activate(entry)
        case .pastePlain:
            activate(entry, transform: .plainText)
        case .copy:
            switch entry {
            case .clip(let item) where item.isTransient: env.paste.write(text: item.text)
            case .clip(let item): copy(item)
            case .secret(let ref):
                noteAuthUse(entry)
                env.copySecret(ref)
            case .emailCode(let code, _): copyEmailCode(code)
            case .snippet, .folder, .authenticator, .authenticatorSuggestion: break
            }
            onClose()
        case .transform(let transform):
            guard let item = entry.clip else { return }
            guard let result = transform.apply(item.text) else {
                showNotice("Can't apply “\(transform.title)” to this item")
                return
            }
            let target = targetApp
            onClose()
            env.paste.paste(text: result, into: target)
        case .ai(let aiAction):
            guard let item = entry.clip else { return }
            var image: AIImage?
            if item.kind == .image {
                guard let file = item.imageFile, let loaded = AIImage.load(from: env.blobs.url(for: file)) else {
                    showNotice("Couldn't read this image")
                    return
                }
                image = loaded
            }
            let run = AIRun(action: aiAction, item: item, providerName: env.prefs.aiProvider.title, image: image)
            aiRun = run
            mode = .ai
            run.start(prefs: env.prefs)
        case .saveAsSecret:
            guard let item = entry.clip else { return }
            beginSaveSecret(item)
        case .setLabel:
            beginLabel(entry)
        case .save:
            beginSave(entry)
        case .shareToGroup:
            if let item = entry.clip {
                beginShare([item])
            } else if case .secret(let ref) = entry {
                beginShareSecret(ref)
            } else if let folder = entry.folder {
                beginShareFolder(folder)
            }
        case .addToSaved:
            guard let item = entry.clip else { return }
            addToSaved([item])
        case .saveCopy:
            guard let item = entry.clip else { return }
            saveCopies([item])
        case .moveToFolder(let folder):
            place(entry.clip.map { [$0] } ?? [], secrets: entry.secret.map { [$0] } ?? [], in: folder)
        case .moveToNewFolder:
            beginNewFolder(moving: entry.clip.map { [$0] } ?? [], secrets: entry.secret.map { [$0] } ?? [])
        case .copyToNewFolder:
            beginNewFolder(moving: entry.clip.map { [$0] } ?? [], secrets: entry.secret.map { [$0] } ?? [], personal: true)
        case .removeFromFolder:
            removeFromFolder(entry.clip.map { [$0] } ?? [], secrets: entry.secret.map { [$0] } ?? [])
        case .openFolder:
            mode = .browse
            if let folder = entry.folder { openFolder(folder) }
        case .renameFolder:
            if let folder = entry.folder { beginRename(folder) }
        case .deleteFolder:
            if let folder = entry.folder { deleteFolder(folder) }
        case .moveFolder(let target):
            if let folder = entry.folder { moveFolder(folder, under: target) }
        case .moveFolderToTop:
            if let folder = entry.folder { moveFolder(folder, under: nil) }
        case .newSubfolder:
            if let folder = entry.folder { beginNewFolder(in: folder) }
        case .sendToDevice(let device):
            guard let item = entry.clip else { return }
            send(item, to: device)
        case .sendToContact(let contact):
            sendToContacts([contact], entries: [entry])
        case .chooseContact:
            beginContactPicker(entries: [entry])
        case .quickLook:
            toggleQuickLook()
        case .setUpAI:
            onClose()
            SettingsOpener.open()
        case .clearSlot(let number):
            env.slots.clear(number)
            mode = .browse
            refresh()
        case .removeFromLabelled:
            guard let item = entry.clip else { return }
            mode = .browse
            removeFromLabelled(item)
        case .saveToFolder:
            guard let item = entry.clip else { return }
            save([item], to: env.prefs.saveFolder)
        case .saveToChosenFolder:
            guard let item = entry.clip else { return }
            saveChoosingFolder([item])
        case .delete:
            mode = .browse
            deleteSelection(includingSecrets: true)
        case .authenticator:
            break   // handled above
        }
    }

    private func performOnSelection(_ action: PanelAction) {
        let clips = selectedClips
        let secrets = selectedSecrets
        switch action {
        case .setLabel:
            beginLabelSelection()
        case .save:
            beginSaveSelection()
        case .paste:
            pasteSelection()
        case .pastePlain:
            pasteSelection(transform: .plainText)
        case .copy:
            env.paste.write(clips, transform: nil)
            onClose()
        case .quickLook:
            toggleQuickLook()
        case .transform(let transform):
            let parts = clips.map { transform.apply($0.text) }
            guard parts.allSatisfy({ $0 != nil }) else {
                showNotice("Can't apply “\(transform.title)” to every selected item")
                return
            }
            let target = targetApp
            onClose()
            env.paste.paste(text: parts.compactMap { $0 }.joined(separator: "\n"), into: target)
        case .shareToGroup:
            beginShare(clips)
        case .sendToContact(let contact):
            sendToContacts([contact], entries: clips.map(PanelEntry.clip))
        case .chooseContact:
            beginContactPicker(entries: clips.map(PanelEntry.clip))
        case .addToSaved:
            addToSaved(clips)
        case .saveCopy:
            saveCopies(clips)
        case .moveToFolder(let folder):
            place(clips, secrets: secrets, in: folder)
        case .moveToNewFolder:
            beginNewFolder(moving: clips, secrets: secrets)
        case .copyToNewFolder:
            beginNewFolder(moving: clips, secrets: secrets, personal: true)
        case .removeFromFolder:
            removeFromFolder(clips, secrets: secrets)
        case .removeFromLabelled:
            removeFromSaved(clips)
        case .saveToFolder:
            save(clips, to: env.prefs.saveFolder)
        case .saveToChosenFolder:
            saveChoosingFolder(clips)
        case .delete:
            mode = .browse
            deleteSelectedClips()
        default:
            break
        }
    }

    // MARK: AI result

    /// Runs the same action again (e.g. after switching model).
    func rerunAI() {
        guard let old = aiRun else { return }
        old.cancel()
        let run = AIRun(action: old.action, item: old.item, providerName: env.prefs.aiProvider.title, image: old.image)
        aiRun = run
        run.start(prefs: env.prefs)
    }

    func pasteAIOutput() {
        guard let run = aiRun, !run.output.isEmpty else { return }
        let target = targetApp
        let text = run.output
        onClose()
        env.paste.paste(text: text, into: target)
    }

    func copyAIOutput() {
        guard let run = aiRun, !run.output.isEmpty else { return }
        env.paste.write(text: run.output)
        showNotice("Copied")
    }

    /// The words recognised in an image, copied as plain text (marked as our own write, so it
    /// doesn't come back as a new history item).
    func copyImageText(_ text: String) {
        guard !text.isEmpty else { return }
        env.paste.write(text: text)
        showNotice("Copied text")
    }

    func replaceItemWithAIOutput() {
        guard let run = aiRun, run.isFinished, !run.item.isTransient else { return }
        env.store.replaceText(of: run.item, with: run.output)
        resetMode()
        refresh()
        selectedID = PanelEntry.clip(run.item).id
        showNotice("Item replaced")
    }

    // MARK: Item actions

    /// Lets an item kept without a label expire like the rest of history.
    func removeFromLabelled(_ item: ClipItem) {
        removeFromSaved([item])
    }

    // MARK: Saved and folder actions

    /// Whether a clip can go into a folder: saved to history, and yours or a group's. A contact's
    /// items stay as they arrived (edits to them never sync).
    func canUseFolders(_ item: ClipItem) -> Bool {
        guard !item.isTransient else { return false }
        guard let space = item.spaceID else { return true }
        return isGroupSpace(space)
    }

    func isGroupSpace(_ spaceID: String?) -> Bool {
        guard let spaceID else { return false }
        return env.sync.groups.contains { $0.id == spaceID }
    }

    /// Whether a secret can go into a folder: yours or a group's (never a contact's).
    func canUseFolders(_ ref: SecretRef) -> Bool {
        guard let space = ref.spaceID else { return true }
        return isGroupSpace(space)
    }

    /// Clips that may move into a folder together: all of one space, folders allowed there.
    func canMoveToFolder(_ clips: [ClipItem]) -> Bool {
        guard let first = clips.first else { return false }
        return clips.allSatisfy { canUseFolders($0) && $0.spaceID == first.spaceID }
    }

    /// The folders the clips can move into (their space's, except the one they're all in already).
    func folderTargets(for clips: [ClipItem]) -> [ClipFolder] {
        guard canMoveToFolder(clips), let first = clips.first else { return [] }
        return env.store.folders(inSpace: first.spaceID).filter { folder in !clips.allSatisfy { $0.folderID == folder.id } }
    }

    /// What Move to Folder offers for a selection.
    struct FolderMenu {
        /// The group the items are all in, with its folders, when they may be moved there.
        var group: (id: String, name: String, folders: [ClipFolder])?
        /// Personal folders ("Mine"): group items go in as personal copies.
        var personal: [ClipFolder]
        /// Some items are a group's, so the personal choices (and New Folder…) save copies.
        var copiesToPersonal: Bool
    }

    /// Move to Folder for clips and secrets: a group's items list the group's folders under its
    /// name (if this account may move them) and your own under "Mine", where they're copied to;
    /// items of several spaces only get "Mine". Nil when the items can't use folders.
    func folderMenu(for clips: [ClipItem], secrets: [SecretRef] = []) -> FolderMenu? {
        let clips = clips.filter { !$0.isTransient }
        guard !clips.isEmpty || !secrets.isEmpty,
              clips.allSatisfy(canUseFolders), secrets.allSatisfy(canUseFolders) else { return nil }
        let spaces = Set(clips.map(\.spaceID) + secrets.map(\.spaceID))
        let allIn = { (folder: ClipFolder) in
            clips.allSatisfy { $0.folderID == folder.id } && secrets.allSatisfy { $0.folderID == folder.id }
        }
        let personal = treeOrderedFolders(inSpace: nil)
        if spaces == [nil] {
            return FolderMenu(group: nil, personal: personal.filter { !allIn($0) }, copiesToPersonal: false)
        }
        var group: (id: String, name: String, folders: [ClipFolder])?
        if spaces.count == 1, let id = spaces.first ?? nil,
           clips.allSatisfy(env.sync.canChange), secrets.allSatisfy({ env.sync.canChange(itemID: $0.id, spaceID: $0.spaceID) }) {
            group = (id, env.sync.groupName(for: id) ?? "Group", treeOrderedFolders(inSpace: id).filter { !allIn($0) })
        }
        return FolderMenu(group: group, personal: personal, copiesToPersonal: true)
    }

    // MARK: Folders in folders

    /// A space's folders, each followed by its subfolders.
    func treeOrderedFolders(inSpace spaceID: String?) -> [ClipFolder] {
        let folders = env.store.folders(inSpace: spaceID)
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return FolderTree(folders).flattened().compactMap { byID[$0.node.id] }
    }

    /// The tree of the folder's space.
    func folderTree(of folder: ClipFolder) -> FolderTree {
        folder.spaceID == savedSpaceID && isSavedView ? savedTree : env.store.tree(inSpace: folder.spaceID)
    }

    /// "Work › Clients".
    func folderPathName(_ folder: ClipFolder) -> String {
        let name = folderTree(of: folder).pathName(of: folder.id)
        return name.isEmpty ? folder.name : name
    }

    /// Moving a group's folder needs its author or the group's owner (the server refuses others).
    func canChangeFolder(_ folder: ClipFolder) -> Bool {
        env.sync.canChange(itemID: folder.id.uuidString, spaceID: folder.spaceID)
    }

    /// The folders a folder may move into: its space's, minus itself, everything below it, its
    /// current parent and anything too deep.
    func folderTargets(forMoving folder: ClipFolder) -> [ClipFolder] {
        let tree = env.store.tree(inSpace: folder.spaceID)
        return treeOrderedFolders(inSpace: folder.spaceID).filter { tree.canMove(folder.id, under: $0.id) }
    }

    func canMoveFolder(_ id: UUID, under target: UUID?) -> Bool {
        guard let folder = env.store.folder(withID: id), canChangeFolder(folder) else { return false }
        if let target {
            guard let parent = env.store.folder(withID: target), parent.spaceID == folder.spaceID else { return false }
        }
        return env.store.tree(inSpace: folder.spaceID).canMove(id, under: target)
    }

    /// Moves a folder (and everything in it) into another folder, or (nil) to the top level.
    @discardableResult
    func moveFolder(_ folder: ClipFolder, under target: ClipFolder?) -> Bool {
        if mode == .actions { mode = .browse }
        guard canMoveFolder(folder.id, under: target?.id), env.store.moveFolder(folder, under: target) else {
            if !env.sync.canSend(to: folder.spaceID) {
                refuseSend(to: folder.spaceID)
                return false
            }
            NSSound.beep()
            showNotice(canChangeFolder(folder) ? "Can't move “\(folder.name)” there" : "Only its author or the group's owner can move it")
            return false
        }
        refresh()
        let id = PanelEntry.folder(folder).id
        if entries.contains(where: { $0.id == id }) { selectedID = id }
        showNotice(target.map { "Moved “\(folder.name)” to \(folderPathName($0))" } ?? "Moved “\(folder.name)” to the top level")
        return true
    }

    /// New Folder Inside…: a subfolder of `folder`.
    func beginNewFolder(in folder: ClipFolder) {
        guard canChangeFolder(folder) || folder.spaceID == nil, env.store.tree(inSpace: folder.spaceID).canCreate(in: folder.id) else {
            NSSound.beep()
            return
        }
        folderNameForm = FolderNameState(purpose: .create(spaceID: folder.spaceID, moving: []), parent: folder)
        mode = .folderName
    }

    /// The folder an item shows in, if any.
    func folder(of item: ClipItem) -> ClipFolder? { env.store.folder(of: item) }

    /// The folder a secret shows in: nil when it has none, or one that isn't in its space.
    func folder(of ref: SecretRef) -> ClipFolder? {
        guard let id = ref.folderID, let folder = env.store.folder(withID: id), folder.spaceID == ref.spaceID else { return nil }
        return folder
    }

    func move(_ clips: [ClipItem], to folder: ClipFolder) {
        place(clips, secrets: [], in: folder)
    }

    /// Puts clips and secrets in a folder. Items of the folder's space move in (a group's only if
    /// this account may change them); group items going into a personal folder are saved there as
    /// personal copies, and the group's stay as they are.
    func place(_ clips: [ClipItem], secrets: [SecretRef], in folder: ClipFolder) {
        if mode == .actions { mode = .browse }
        let clips = clips.filter { !$0.isTransient && canUseFolders($0) }
        let secrets = secrets.filter(canUseFolders)
        let mayMove = { [env] (id: String, space: String?) in space == folder.spaceID && env.sync.canChange(itemID: id, spaceID: space) }
        let movingClips = clips.filter { mayMove($0.id.uuidString, $0.spaceID) }
        let movingSecrets = secrets.filter { mayMove($0.id, $0.spaceID) }
        // Only a personal folder takes copies of other spaces' items.
        let copyingClips = folder.spaceID == nil ? clips.filter { $0.spaceID != nil } : []
        let copyingSecrets = folder.spaceID == nil ? secrets.filter { $0.spaceID != nil } : []
        guard !movingClips.isEmpty || !movingSecrets.isEmpty || !copyingClips.isEmpty || !copyingSecrets.isEmpty else {
            NSSound.beep()
            let refused = clips.contains { $0.spaceID == folder.spaceID } || secrets.contains { $0.spaceID == folder.spaceID }
            if refused && !env.sync.canSend(to: folder.spaceID) { return refuseSend(to: folder.spaceID) }
            showNotice(refused ? "Only its author or the group's owner can move it"
                       : "Only items from the same place can go in “\(folder.name)”")
            return
        }
        env.store.move(movingClips, to: folder)
        env.secrets.setFolder(folder.id, for: movingSecrets)
        env.store.savePersonalCopies(of: copyingClips, into: folder)
        let moved = movingClips.count + movingSecrets.count
        let copied = copyingClips.count + copyingSecrets.count
        let notice = copied == 0
            ? (moved == 1 ? "Moved to “\(folder.name)”" : "Moved \(moved) items to “\(folder.name)”")
            : (copied == 1 ? "Saved a copy to “\(folder.name)”" : "Saved \(copied) copies to “\(folder.name)”")
        if copyingSecrets.isEmpty {
            refresh()
            showNotice(notice)
        } else {
            copySecretsToPersonal(copyingSecrets, folder: folder) { [weak self] in
                self?.refresh()
                self?.showNotice(notice)
            }
        }
    }

    /// Personal copies of group secrets (after Touch ID), in `folder` or at the root of Saved.
    private func copySecretsToPersonal(_ refs: [SecretRef], folder: ClipFolder?, then: @escaping () -> Void) {
        Task {
            let what = refs.count == 1 ? "“\(refs[0].name)”" : "\(refs.count) secrets"
            guard await env.secrets.authenticate(reason: "save a copy of \(what)") else { return }
            let personal = env.secrets.secrets.filter { $0.spaceID == nil }
            for ref in refs {
                guard let value = SecretVault.value(id: ref.id) else { continue }
                if let same = personal.first(where: { $0.name == ref.name && SecretVault.value(id: $0.id) == value }) {
                    if let folder { env.secrets.setFolder(folder.id, for: [same]) }
                } else {
                    env.secrets.add(name: ref.name, value: value, folderID: folder?.id)
                }
            }
            then()
        }
    }

    func removeFromFolder(_ clips: [ClipItem], secrets: [SecretRef] = []) {
        if mode == .actions { mode = .browse }
        env.store.removeFromFolder(clips)
        env.secrets.setFolder(nil, for: secrets)
        refresh()
        showNotice("Moved to Saved")
    }

    func addToSaved(_ clips: [ClipItem]) {
        if mode == .actions { mode = .browse }
        env.store.addToSaved(clips)
        refresh()
        showNotice(clips.count == 1 ? "Added to Saved" : "Added \(clips.count) items to Saved")
    }

    /// Save a Copy: personal copies of (another member's) group items, at the root of your Saved.
    /// The group's items don't change.
    func saveCopies(_ clips: [ClipItem]) {
        if mode == .actions { mode = .browse }
        let copies = env.store.savePersonalCopies(of: clips.filter { $0.spaceID != nil })
        refresh()
        showNotice(copies.count == 1 ? "Saved a copy to Saved" : "Saved \(copies.count) copies to Saved")
    }

    /// Lets saved items without a label expire again (out of their folder too).
    func removeFromSaved(_ clips: [ClipItem]) {
        if mode == .actions { mode = .browse }
        env.store.removeFromSaved(clips)
        refresh()
        showNotice("Removed from Saved")
    }

    /// Names a new folder in the panel; `moving` clips and `secrets` go into it (Move to Folder ▸
    /// New Folder…). `personal`: a personal folder, taking copies of group items.
    /// `parent`: the level it's created at (a folder of that space); without one, the open
    /// folder when nothing moves into it (New Folder inside an open folder makes a subfolder).
    func beginNewFolder(moving clips: [ClipItem] = [], secrets: [SecretRef] = [], personal: Bool = false,
                        parent: ClipFolder? = nil) {
        let space = personal ? nil : clips.first?.spaceID ?? secrets.first?.spaceID ?? (clips.isEmpty && secrets.isEmpty ? savedSpaceID : nil)
        if clips.isEmpty && secrets.isEmpty {
            guard space == nil || isGroupSpace(space) else { return }
            guard env.sync.canSend(to: space) else { return refuseSend(to: space) }
        } else {
            guard let menu = folderMenu(for: clips, secrets: secrets) else { return }
            // Into a group's new folder only when its items may be moved there.
            if space != nil && menu.group == nil { return }
        }
        var level = parent.flatMap { $0.spaceID == space ? $0 : nil }
        if parent == nil, clips.isEmpty, secrets.isEmpty, space == savedSpaceID { level = openFolder }
        if let level, !env.store.tree(inSpace: space).canCreate(in: level.id) {
            NSSound.beep()
            showNotice("Folders go at most \(FolderTree.maxDepth) levels deep")
            return
        }
        folderNameForm = FolderNameState(purpose: .create(spaceID: space, moving: clips, secrets: secrets), parent: level)
        mode = .folderName
    }

    func beginRename(_ folder: ClipFolder) {
        selectedID = PanelEntry.folder(folder).id
        folderNameForm = FolderNameState(purpose: .rename(folder))
        mode = .folderName
    }

    func submitFolderName() {
        guard let form = folderNameForm else { return }
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            NSSound.beep()
            return
        }
        switch form.purpose {
        case .rename(let folder):
            env.store.rename(folder, to: name)
            resetMode()
            refresh()
            selectedID = PanelEntry.folder(folder).id
            showNotice("Renamed to “\(folder.name)”")
        case .create(let space, let moving, let secrets):
            let folder = env.store.createFolder(named: name, inSpace: space, parent: form.parent)
            resetMode()
            if moving.isEmpty && secrets.isEmpty {
                refresh()
                let id = PanelEntry.folder(folder).id
                if entries.contains(where: { $0.id == id }) { selectedID = id }
                showNotice("Created “\(folder.name)”")
            } else {
                place(moving, secrets: secrets, in: folder)
            }
        }
    }

    /// Its clips, secrets and subfolders move up to its parent (the root of Saved for a
    /// top-level folder); nothing to confirm.
    func deleteFolder(_ folder: ClipFolder) {
        if mode == .actions { mode = .browse }
        let index = selectedIndex
        let tree = env.store.tree(inSpace: folder.spaceID)
        let parentID = tree.parent(of: folder.id)
        let parent = parentID.flatMap(env.store.folder(withID:))
        if let open = openFolderID, tree.subtree(of: folder.id).contains(open) { openFolderID = parentID }
        // Its secrets go up a level too (and re-sync with the new place), like its clips.
        let secrets = env.secrets.secrets(inFolder: folder)
        env.secrets.setFolder(parentID, for: secrets)
        let moved = env.store.deleteFolder(folder) + secrets.count
        refresh()
        if let index, !entries.isEmpty { selectedID = entries[min(index, entries.count - 1)].id }
        showNotice("Folder deleted · moved \(moved) \(moved == 1 ? "item" : "items") to \(parent.map { folderPathName($0) } ?? "Saved")")
    }

    /// ⌫ never deletes secrets (too easy to hit by accident); ⌘K → Delete does.
    func deleteSelection(includingSecrets: Bool = false) {
        guard let entry = selectedEntry, let index = selectedIndex else { return }
        switch entry {
        case .clip(let item):
            env.slots.remove(target: .clip(item.id))
            env.store.delete(item)
        case .secret(let ref):
            guard includingSecrets else { return }
            env.slots.remove(target: .secret(ref.id))
            env.secrets.delete(ref)
        case .folder(let folder):
            deleteFolder(folder)   // nothing is lost: its clips move to the root
            return
        case .snippet:
            return   // snippets are edited in Settings
        case .authenticator(let item):
            // ⌫ asks first (like ⌘K → Delete); it never deletes one straight away.
            if includingSecrets, case .owned(let authenticator) = item { askToDelete(authenticator) }
            return
        case .authenticatorSuggestion:
            dismissSuggestion()
            return
        case .emailCode:
            return   // they go by themselves after 10 minutes
        }
        refresh()
        if !entries.isEmpty {
            selectedID = entries[min(index, entries.count - 1)].id
        }
    }

    // MARK: Keyboard

    /// Returns true when the event was handled and must not reach the search field.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        switch mode {
        case .browse: handleBrowseKey(event)
        case .actions: handleActionKey(event)
        case .snippetForm, .saveSecret, .label, .editSecret, .folderName, .authenticatorForm: handleFormKey(event)
        case .shareToGroup: handleShareKey(event)
        case .ai: handleAIKey(event)
        case .authenticatorPeople: handlePeopleKey(event)
        case .folderPicker: handlePickerKey(event)
        case .addItems: handleAddItemsKey(event)
        case .contactPicker: handleContactPickerKey(event)
        case .addContact: handleAddContactKey(event)
        case .save: handleSaveKey(event)
        }
    }

    private func handlePickerKey(_ event: NSEvent) -> Bool {
        guard let form = folderPicker else { return false }
        switch event.keyCode {
        case KeyCode.escape:
            resetMode()
        case KeyCode.upArrow:
            form.selection = max(0, form.selection - 1)
        case KeyCode.downArrow:
            form.selection = min(max(0, form.rows.count - 1), form.selection + 1)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if form.rows.indices.contains(form.selection) { pick(form.rows[form.selection]) }
        default:
            return false
        }
        return true
    }

    /// The search field keeps typing; ↑↓ move, space toggles, Return adds, esc cancels.
    private func handleAddItemsKey(_ event: NSEvent) -> Bool {
        guard let form = addItemsForm else { return false }
        switch event.keyCode {
        case KeyCode.escape:
            resetMode()
        case KeyCode.upArrow:
            form.selection = max(0, form.selection - 1)
        case KeyCode.downArrow:
            form.selection = min(max(0, form.shown.count - 1), form.selection + 1)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            submitAddItems()
        case KeyCode.space:
            form.toggleSelected()
        default:
            return false
        }
        return true
    }

    private func handlePeopleKey(_ event: NSEvent) -> Bool {
        guard let form = peopleForm else { return false }
        switch event.keyCode {
        case KeyCode.escape:
            resetMode()
        case KeyCode.upArrow:
            form.selection = max(0, form.selection - 1)
        case KeyCode.downArrow:
            form.selection = min(max(0, form.rowCount - 1), form.selection + 1)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            submitPeople()
        default:
            return false
        }
        return true
    }

    private func handleBrowseKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if showsPeople, let handled = handlePeopleKey(event, command: command, chars: chars) { return handled }

        switch event.keyCode {
        case KeyCode.escape:
            // Quick Look closes first, then an open folder; the panel on the next press.
            if isQuickLookOpen() {
                onQuickLook(false)
            } else if pendingDeleteID != nil {
                cancelDelete()
            } else if revealedSecretID != nil {
                hideSecret()
            } else if entries.first?.isSuggestion == true {
                dismissSuggestion()
            } else if openFolderID != nil {
                closeFolder()
            } else if previewSelection != nil {
                previewSelection = nil
            } else if !isPinned {
                onClose()   // kept open, esc at the top level does nothing
            }
            return true
        case KeyCode.leftArrow where openFolderID != nil && query.isEmpty && !command && !shift:
            closeFolder()
            return true
        case KeyCode.rightArrow where query.isEmpty && !command && !shift && selectedEntry?.folder != nil && !isMultiSelecting:
            activate(selectedEntry)
            return true
        case KeyCode.upArrow:
            moveSelection(by: -1, extending: shift)
            return true
        case KeyCode.downArrow:
            moveSelection(by: 1, extending: shift)
            return true
        case KeyCode.pageUp:
            moveSelection(by: -8, extending: shift)
            return true
        case KeyCode.pageDown:
            moveSelection(by: 8, extending: shift)
            return true
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if previewSelection != nil && !isMultiSelecting {
                pastePreviewSelection()
            } else if isMultiSelecting {
                pasteSelection(transform: option ? .plainText : nil)
            } else {
                activate(selectedEntry, transform: option ? .plainText : nil)
            }
            return true
        case KeyCode.tab:
            cycleFilter(forward: !shift)
            return true
        case KeyCode.delete, KeyCode.forwardDelete:
            // With text in the search field every delete variant edits the text
            // (⌥⌫ deletes a word, ⌘⌫ the line); only an empty field deletes items.
            guard query.isEmpty else { return false }
            // Inside a folder, ⌫ goes up one level (like esc and ←); ⌘K → Delete still deletes.
            if event.keyCode == KeyCode.delete, openFolderID != nil, !command {
                closeFolder()
                return true
            }
            if isMultiSelecting { deleteSelectedClips() } else { deleteSelection() }
            return true
        default:
            break
        }

        if command {
            // Digits by key code so ⌘⇧1 works on every keyboard layout.
            if let digit = KeyCode.digit(for: event.keyCode) {
                if shift {
                    assignSelection(toSlot: digit)
                } else {
                    activateShortcut(digit, transform: option ? .plainText : nil)
                }
                return true
            }
            switch chars {
            case "c" where previewSelection != nil && !shift && !option:
                copyPreviewSelection()
                return true
            case "a":
                // With an empty search field ⌘A selects every row; otherwise it selects the text.
                guard query.isEmpty else { return false }
                selectAll()
                return true
            case "k":
                openActions()
                return true
            case "e":
                beginEditing()
                return true
            case "s" where !shift:
                beginSaveSelection()
                return true
            case "l" where !shift:
                // Clips are labelled in Save…; secrets and folders keep Label….
                if selectedClips.isEmpty || !selectedSecrets.isEmpty || selectedEntry?.clip == nil {
                    beginLabelSelection()
                } else {
                    beginSaveSelection()
                }
                return true
            case "m" where shift:
                // Clips move in Save…; secrets keep the folder picker.
                if selectedSecrets.isEmpty && selectedEntry?.secret == nil { beginSaveSelection() } else { beginFolderPicker() }
                return true
            case "y":
                toggleQuickLook()
                return true
            case ",":
                onClose()
                SettingsOpener.open()
                return true
            default:
                break
            }
        }
        return false
    }

    /// The action filter is a real text field, so typing and text editing (⌥⌫, ⌘⌫, ⌘A…)
    /// go to it; only navigation keys are intercepted here.
    private func handleActionKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let actions = filteredActions
        switch event.keyCode {
        case KeyCode.escape:
            if isSelectionMode { onClose() } else { mode = .browse }
        case KeyCode.upArrow:
            actionSelection = max(0, actionSelection - 1)
        case KeyCode.downArrow:
            actionSelection = min(max(0, actions.count - 1), actionSelection + 1)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if actions.indices.contains(actionSelection) { perform(actions[actionSelection]) }
        default:
            guard flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "k" else { return false }
            mode = .browse
        }
        return true
    }

    private func handleFormKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case KeyCode.escape:
            resetMode()
            return true
        case KeyCode.returnKey, KeyCode.keypadEnter:
            switch mode {
            case .saveSecret: submitSaveSecret()
            case .label: submitLabel()
            case .folderName: submitFolderName()
            case .editSecret: submitEditSecret()
            case .authenticatorForm: submitAuthenticatorForm()
            default: submitSnippetForm()
            }
            return true
        default:
            return false
        }
    }

    private func handleShareKey(_ event: NSEvent) -> Bool {
        guard let form = shareForm else { return false }
        switch event.keyCode {
        case KeyCode.escape:
            if isSelectionMode { mode = .actions } else { resetMode() }
        case KeyCode.upArrow:
            form.selection = max(0, form.selection - 1)
        case KeyCode.downArrow:
            form.selection = min(form.groups.count - 1, form.selection + 1)
        case KeyCode.leftArrow:
            form.moveDestination(by: -1)
        case KeyCode.rightArrow:
            form.moveDestination(by: 1)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            submitShare()
        default:
            return false
        }
        return true
    }

    private func handleAIKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case KeyCode.escape:
            if isSelectionMode {
                aiRun?.cancel()
                aiRun = nil
                mode = .actions
            } else {
                resetMode()
            }
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if aiRun?.isFinished == true { pasteAIOutput() }
        default:
            if flags.contains(.command) {
                if chars == "c" { copyAIOutput() }
                if chars == "r" { replaceItemWithAIOutput() }
            }
        }
        return true
    }
}

nonisolated enum KeyCode {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let keypadEnter: UInt16 = 76
    static let pageUp: UInt16 = 116
    static let forwardDelete: UInt16 = 117
    static let pageDown: UInt16 = 121
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126

    /// kVK_ANSI_1 … kVK_ANSI_9 (positional, layout independent).
    private static let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
    static func digit(for keyCode: UInt16) -> Int? { digits[keyCode] }
}

// MARK: - Contacts: People, Send to Contact…, notifications

/// A refusal shown as is.
nonisolated struct PanelMessage: LocalizedError {
    var errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

extension PanelViewModel {
    /// Contacts → People is showing (instead of a list of entries).
    var showsPeople: Bool { selectionItem == nil && groupFilter == nil && filter == .inbox && contactsShowPeople }

    /// What new items the panel shows right now: a group's, or the Inbox's (nil for anything else).
    var arrivalPlaceShown: ArrivalPlace? {
        if let groupFilter { return .group(groupFilter) }
        return filter == .inbox && !contactsShowPeople ? .inbox : nil
    }

    var selectedPerson: PeopleRow? { people.first { $0.id == peopleSelectionID } }

    func refreshPeople(resetSelection: Bool) {
        people = PeopleList.rows(contacts: env.sync.contacts, requests: env.sync.contactRequests,
                                 lastExchange: lastExchange, query: query)
        if resetSelection || !people.contains(where: { $0.id == peopleSelectionID }) {
            peopleSelectionID = people.first?.id
        }
    }

    func refreshLastExchange() {
        guard env.sync.isSignedIn, !env.sync.contacts.isEmpty else {
            if !lastExchange.isEmpty { lastExchange = [:] }
            return
        }
        let fresh = env.sync.lastExchange()
        if fresh != lastExchange { lastExchange = fresh }
    }

    func showInbox() { select(.chip(.inbox)) }

    /// A notification was clicked: the panel shows what it was about.
    func reveal(_ target: NotificationTarget) {
        resetMode()
        query = ""
        switch target {
        case .group(let id):
            guard env.sync.groups.contains(where: { $0.id == id }) else { return }
            select(.group(id, saved: false))
        case .groupItem(let id, let entryID, let saved):
            guard env.sync.groups.contains(where: { $0.id == id }) else { return }
            select(.group(id, saved: saved))
            focus(entryID)
        case .people(let request):
            select(.people)
            if let request, people.contains(where: { $0.id == "in-" + request }) { peopleSelectionID = "in-" + request }
        case .inbox(let entryID):
            select(.chip(.inbox))
            focus(entryID)
        case .authenticator(let spaceId):
            select(.chip(.auth))
            let item = env.authenticators.items.first { $0.owned?.spaceID == spaceId || $0.shared?.spaceId == spaceId }
            focus(item.map { PanelEntry.authenticator($0).id })
        case .emailCode(let id):
            select(.chip(.auth))
            focus(env.emailCodes.code(id: id).map { PanelEntry.emailCode($0).id })
        }
    }

    private func focus(_ entryID: String?) {
        guard let entryID, entries.contains(where: { $0.id == entryID }) else { return }
        selectedID = entryID
        userMovedSelection = true
    }

    // MARK: People

    private func movePeople(by delta: Int) {
        guard !people.isEmpty else { return }
        let current = people.firstIndex { $0.id == peopleSelectionID } ?? (delta > 0 ? -1 : people.count)
        peopleSelectionID = people[min(max(current + delta, 0), people.count - 1)].id
    }

    /// nil: not a People key (the usual browse handling applies).
    fileprivate func handlePeopleKey(_ event: NSEvent, command: Bool, chars: String) -> Bool? {
        switch event.keyCode {
        case KeyCode.escape:
            guard pendingRemoveContactID != nil else { return nil }
            cancelRemove()
            return true
        case KeyCode.upArrow:
            movePeople(by: -1)
            return true
        case KeyCode.downArrow:
            movePeople(by: 1)
            return true
        case KeyCode.returnKey, KeyCode.keypadEnter:
            switch selectedPerson {
            case .incoming(let request): accept(request)
            case .contact(let contact):
                if pendingRemoveContactID == contact.id { remove(contact) } else { beginSendItems(to: contact) }
            case .outgoing, nil: NSSound.beep()
            }
            return true
        case KeyCode.delete, KeyCode.forwardDelete:
            guard query.isEmpty else { return false }
            if let contact = selectedPerson?.contact { askToRemove(contact) } else { NSSound.beep() }
            return true
        default:
            if command && chars == "n" {
                beginAddContact()
                return true
            }
            return nil
        }
    }

    func accept(_ request: ContactRequest) {
        Task {
            do {
                try await env.sync.accept(request)
                showNotice("You and \(request.name) are now contacts")
            } catch {
                showNotice(error.localizedDescription)
            }
            refresh()
        }
    }

    /// Declines an incoming request or cancels an outgoing one.
    func dismiss(_ request: ContactRequest) {
        Task {
            do {
                try await env.sync.dismiss(request)
            } catch {
                showNotice(error.localizedDescription)
            }
            refresh()
        }
    }

    /// Remove Contact…: an inline confirm in the right pane (never a dialog).
    func askToRemove(_ contact: SyncContact) {
        peopleSelectionID = "p-" + contact.id
        pendingRemoveContactID = contact.id
    }

    func cancelRemove() { pendingRemoveContactID = nil }

    func remove(_ contact: SyncContact) {
        pendingRemoveContactID = nil
        Task {
            do {
                try await env.sync.remove(contact)
                showNotice("Removed \(contact.name)")
            } catch {
                showNotice(error.localizedDescription)
            }
            refresh()
        }
    }

    /// Send… on a contact: recent history to tick, as in Add Items.
    func beginSendItems(to contact: SyncContact) {
        let candidates = env.store.items(inSpace: nil).filter { !$0.isTransient && !$0.isConcealed }
        addItemsForm = AddItemsState(candidates: Array(candidates.prefix(Self.maxEntries)), folder: nil, contact: contact)
        mode = .addItems
    }

    // MARK: Add Contact

    func beginAddContact() {
        guard env.sync.isSignedIn else {
            NSSound.beep()
            return
        }
        addContactForm = AddContactState()
        mode = .addContact
    }

    func submitAddContact() {
        guard let form = addContactForm, !form.busy else { return }
        let text = form.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preview = form.preview {
            runContactForm(form) {
                try await self.env.sync.addContact(preview)
                self.finishAddContact("\(preview.name) is now your contact")
            }
        } else if AddContactState.isCode(text) {
            runContactForm(form) {
                let preview = try await self.env.sync.previewInvite(code: text)
                guard preview.isContact else {
                    throw PanelMessage("That's a group invite code. Join groups in Settings → Sync.")
                }
                form.preview = preview
            }
        } else if !text.isEmpty {
            runContactForm(form) {
                let request = try await self.env.sync.requestContact(username: text)
                self.finishAddContact("Request sent to \(request.name)")
            }
        } else {
            NSSound.beep()
        }
    }

    func createContactCode() {
        guard let form = addContactForm, !form.busy else { return }
        runContactForm(form) {
            form.code = try await self.env.sync.createContactCode()
            form.copied = false
        }
    }

    private func runContactForm(_ form: AddContactState, _ work: @escaping () async throws -> Void) {
        form.busy = true
        form.error = nil
        Task {
            do {
                try await work()
            } catch {
                form.error = error.localizedDescription
            }
            form.busy = false
        }
    }

    private func finishAddContact(_ text: String) {
        resetMode()
        if !showsPeople { select(.people) }
        refresh()
        showNotice(text)
    }

    fileprivate func handleAddContactKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case KeyCode.escape:
            resetMode()
        case KeyCode.returnKey, KeyCode.keypadEnter:
            submitAddContact()
        default:
            return false
        }
        return true
    }

    // MARK: Send to Contact…

    /// What a contact can't get: what a contact sent you (it goes no further).
    func canSendToContact(_ item: ClipItem) -> Bool { !sendableContacts.isEmpty && !env.sync.isFromContact(item) }

    func canSendToContact(_ ref: SecretRef) -> Bool { !sendableContacts.isEmpty && !env.sync.isFromContact(secret: ref) }

    /// The rows a context-menu action on `entry` applies to: the selection if it's part of one.
    func entriesForContextAction(on entry: PanelEntry) -> [PanelEntry] {
        isMultiSelecting && isSelected(entry) ? entries.filter { selectedIDs.contains($0.id) } : [entry]
    }

    /// What sending `entries` sends: clips and secrets, a folder's whole subtree (its saved clips
    /// and secrets), never what contacts sent you.
    func contactItems(for entries: [PanelEntry]) -> (clips: [ClipItem], secrets: [SecretRef]) {
        var clips: [ClipItem] = []
        var secrets: [SecretRef] = []
        for entry in entries {
            switch entry {
            case .clip(let item):
                clips.append(item)
            case .secret(let ref):
                secrets.append(ref)
            case .folder(let folder):
                let ids = FolderTree(env.store.folders(inSpace: folder.spaceID)).subtree(of: folder.id)
                clips += env.store.items(inSpace: folder.spaceID).filter { $0.isPinned && $0.folderID.map(ids.contains) == true }
                secrets += env.secrets.secrets.filter { $0.spaceID == folder.spaceID && $0.folderID.map(ids.contains) == true }
            case .snippet, .authenticator, .authenticatorSuggestion, .emailCode:
                break
            }
        }
        var seenClips = Set<UUID>(), seenSecrets = Set<String>()
        clips = clips.filter { !env.sync.isFromContact($0) && seenClips.insert($0.id).inserted }
        secrets = secrets.filter { !env.sync.isFromContact(secret: $0) && seenSecrets.insert($0.id).inserted }
        return (clips, secrets)
    }

    /// Secrets are sent only after Touch ID (or within the unlock grace period). nil: not allowed.
    private func unlock(_ refs: [SecretRef]) async -> [(ref: SecretRef, value: String)]? {
        guard !refs.isEmpty else { return [] }
        let reason = refs.count == 1 ? "send “\(refs[0].name)” to a contact" : "send \(refs.count) secrets to a contact"
        let allowed = if let authenticateSecrets { await authenticateSecrets(reason) } else { await env.secrets.authenticate(reason: reason) }
        guard allowed else { return nil }
        return refs.compactMap { ref in SecretVault.value(id: ref.id).map { (ref: ref, value: $0) } }
    }

    /// Send to Contact…: the picker in the right pane, for these rows.
    func beginContactPicker(entries: [PanelEntry]) {
        let (clips, refs) = contactItems(for: entries)
        guard !sendableContacts.isEmpty else {
            NSSound.beep()
            showNotice("Add a contact in Contacts → People first")
            return
        }
        guard !clips.isEmpty || !refs.isEmpty else {
            NSSound.beep()
            showNotice("Nothing here can be sent to a contact")
            return
        }
        if let problem = clips.lazy.compactMap(SyncEngine.groupShareProblem).first {
            refuseGroupShare(problem.replacingOccurrences(of: "Groups take", with: "Sync takes"))
            return
        }
        let open = { (secrets: [(ref: SecretRef, value: String)]) in
            self.refreshLastExchange()
            // Not back into the space everything already is in.
            let spaces = Set(clips.map(\.spaceID) + refs.map(\.spaceID))
            let contacts = self.rankedContacts.filter { !(spaces.count == 1 && spaces.first == $0.id) }
            self.contactPicker = ContactPickerState(clips: clips, secrets: secrets, contacts: contacts)
            self.mode = .contactPicker
        }
        if refs.isEmpty {
            open([])
        } else {
            Task {
                guard let secrets = await unlock(refs) else { return }
                open(secrets)
            }
        }
    }

    func submitContactPicker(adding: Bool) {
        guard let form = contactPicker else { return }
        let recipients = form.recipients(adding: adding)
        guard !recipients.isEmpty else {
            NSSound.beep()
            return
        }
        deliver(clips: form.clips, secrets: form.secrets, to: recipients)
    }

    /// "Send to ‹name›" rows (⌘K) and the like: straight to these contacts.
    func sendToContacts(_ contacts: [SyncContact], entries: [PanelEntry]) {
        let (clips, refs) = contactItems(for: entries)
        guard !clips.isEmpty || !refs.isEmpty else {
            NSSound.beep()
            showNotice("Nothing here can be sent to a contact")
            return
        }
        if refs.isEmpty {
            deliver(clips: clips, secrets: [], to: contacts)
        } else {
            Task {
                guard let secrets = await unlock(refs) else { return }
                deliver(clips: clips, secrets: secrets, to: contacts)
            }
        }
    }

    fileprivate func handleContactPickerKey(_ event: NSEvent) -> Bool {
        guard let form = contactPicker else { return false }
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        switch event.keyCode {
        case KeyCode.escape:
            if isSelectionMode {
                contactPicker = nil
                mode = .actions
            } else {
                resetMode()
            }
        case KeyCode.upArrow:
            form.selection = max(0, form.selection - 1)
        case KeyCode.downArrow:
            form.selection = min(max(0, form.shown.count - 1), form.selection + 1)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            submitContactPicker(adding: command)
        case KeyCode.space:
            // Usernames have no spaces: space ticks, like in Add Items.
            form.toggleHighlighted()
        default:
            return false
        }
        return true
    }
}

// MARK: - Save… (docs/features/panel-v3.md §6)

extension PanelViewModel {
    /// Saved already, where this account keeps it: pinned, and yours or a group's you can change.
    func isSaved(_ item: ClipItem) -> Bool {
        item.isPinned && !env.sync.isContactItem(item) && env.sync.canChange(item)
    }

    /// Save… works on history items (never selected text from another app).
    func canSave(_ clips: [ClipItem]) -> Bool {
        !clips.isEmpty && clips.allSatisfy { !$0.isTransient }
    }

    /// Save… / Edit Saved… for one row.
    func beginSave(_ entry: PanelEntry) {
        guard let item = entry.clip, canSave([item]) else {
            NSSound.beep()
            return
        }
        selectedID = entry.id
        beginSave(clips: [item])
    }

    /// ⌘S: Save… for the selection's clips.
    func beginSaveSelection() {
        let clips = isMultiSelecting ? selectedClips : selectedEntry?.clip.map { [$0] } ?? []
        guard canSave(clips) else {
            NSSound.beep()
            return
        }
        beginSave(clips: clips)
    }

    func beginSave(clips: [ClipItem]) {
        let groups = env.sync.isSignedIn ? shareGroups : []
        var destination = SaveDestination.mine(nil)
        var editing = false
        if clips.count == 1, isSaved(clips[0]) {
            let item = clips[0]
            editing = true
            let folder = env.store.folder(of: item)?.id
            destination = isGroupSpace(item.spaceID) ? .group(item.spaceID ?? "", folder) : .mine(folder)
        }
        saveForm = SaveFormState(clips: clips, isEditing: editing, destination: destination,
                                 personalFolders: env.store.folders(inSpace: nil), groups: groups,
                                 groupFolders: Dictionary(groups.map { ($0.id, env.store.folders(inSpace: $0.id)) },
                                                          uniquingKeysWith: { first, _ in first }))
        mode = .save
    }

    func submitSave() {
        guard let form = saveForm else { return }
        let ids = selectedIDs
        let focus = selectedID
        resetMode()
        save(form.clips, label: form.showsLabel ? form.label : nil, to: form.destination)
        let live = Set(entries.map(\.id))
        if let focus, live.contains(focus) { setSelection(ids.intersection(live), focus: focus) }
    }

    /// Saves the clips into `destination`.
    /// - Your Saved: pinned, labelled, in the folder (or none). A group's or contact's item is
    ///   saved as a personal copy, like Save a Copy.
    /// - A group: a copy is shared into it (or its folder) with the label; one already there that
    ///   this account may change is just labelled and moved.
    /// `label` nil (several items) leaves labels as they are.
    func save(_ clips: [ClipItem], label: String?, to destination: SaveDestination) {
        let clips = clips.filter { !$0.isTransient }
        guard !clips.isEmpty else { return }
        let kept: [ClipItem]
        let place: String
        var copied = false
        switch destination {
        case .mine(let folderID):
            let folder = folderID.flatMap(env.store.folder(withID:)).flatMap { $0.spaceID == nil ? $0 : nil }
            copied = clips.contains { $0.spaceID != nil }
            kept = clips.flatMap { $0.spaceID == nil ? [$0] : env.store.savePersonalCopies(of: [$0]) }
            place = folder.map { "“\($0.name)”" } ?? "Saved"
            keep(kept, label: label, folder: folder)
        case .group(let groupID, let folderID):
            guard let group = env.sync.groups.first(where: { $0.id == groupID }), group.canSend else {
                return refuseSend(to: groupID)
            }
            if let problem = clips.lazy.compactMap(SyncEngine.groupShareProblem).first {
                refuseGroupShare(problem)
                return
            }
            let folder = folderID.flatMap(env.store.folder(withID:)).flatMap { $0.spaceID == groupID ? $0 : nil }
            copied = clips.contains { $0.spaceID != groupID }
            let copies = clips.map { $0.spaceID == groupID ? $0 : env.store.shareCopy(of: $0, toSpace: groupID) }
            // Copies that were already in the group (same content) only change if this account may.
            kept = copies.filter { env.sync.canChange($0) }
            place = folder.map { "“\($0.name)” in \(group.name)" } ?? group.name
            keep(kept, label: label, folder: folder)
            env.sync.syncNow()
        }
        refresh()
        let count = clips.count
        showNotice(copied ? (count == 1 ? "Saved a copy to \(place)" : "Saved \(count) copies to \(place)")
                   : (count == 1 ? "Saved to \(place)" : "Saved \(count) items to \(place)"))
    }

    /// Pinned, labelled (unless `label` is nil) and in `folder`, or out of any folder.
    private func keep(_ items: [ClipItem], label: String?, folder: ClipFolder?) {
        guard !items.isEmpty else { return }
        if let label {
            for item in items { env.store.setLabel(label, for: item, keepPinned: true) }
        }
        env.store.addToSaved(items)
        if let folder { env.store.move(items, to: folder) } else { env.store.removeFromFolder(items) }
    }

    /// New Folder at the bottom of a list: named inline, below the list.
    func beginSaveFormFolder(_ side: SaveFormState.Side) {
        guard let form = saveForm, form.newFolderPlace(side) != nil else {
            NSSound.beep()
            return
        }
        form.newFolderName = ""
        form.newFolderSide = side
    }

    /// Creates the folder at the picked level and picks it.
    func createSaveFormFolder() {
        guard let form = saveForm, let side = form.newFolderSide, let place = form.newFolderPlace(side) else { return }
        let name = form.newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            NSSound.beep()
            return
        }
        guard env.sync.canSend(to: place.spaceID) else { return refuseSend(to: place.spaceID) }
        var parent = place.parentID.flatMap(env.store.folder(withID:))
        if let level = parent, !env.store.tree(inSpace: place.spaceID).canCreate(in: level.id) {
            // Too deep: next to the picked folder instead.
            parent = env.store.tree(inSpace: place.spaceID).parent(of: level.id).flatMap(env.store.folder(withID:))
        }
        let folder = env.store.createFolder(named: name, inSpace: place.spaceID, parent: parent)
        if let space = place.spaceID {
            form.groupFolders[space] = env.store.folders(inSpace: space)
            env.sync.syncNow()
        } else {
            form.personalFolders = env.store.folders(inSpace: nil)
        }
        form.newFolderSide = nil
        form.newFolderName = ""
        form.destination = place.spaceID.map { .group($0, folder.id) } ?? .mine(folder.id)
    }

    /// The form's text fields keep typing; ↑↓ pick, Return saves (or names the new folder), esc
    /// backs out of the new folder, then the form.
    fileprivate func handleSaveKey(_ event: NSEvent) -> Bool {
        guard let form = saveForm else { return false }
        switch event.keyCode {
        case KeyCode.escape:
            if form.newFolderSide != nil { form.newFolderSide = nil } else { resetMode() }
        case KeyCode.upArrow where form.newFolderSide == nil:
            form.moveDestination(by: -1)
        case KeyCode.downArrow where form.newFolderSide == nil:
            form.moveDestination(by: 1)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if form.newFolderSide != nil { createSaveFormFolder() } else { submitSave() }
        default:
            return false
        }
        return true
    }
}
