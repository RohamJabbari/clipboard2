import AppKit
import Observation

nonisolated enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

extension AppearanceMode {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

nonisolated enum PanelSize: String, CaseIterable, Identifiable, Sendable {
    case compact, regular, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var size: CGSize {
        switch self {
        case .compact: CGSize(width: 660, height: 400)
        case .regular: CGSize(width: 780, height: 480)
        case .large: CGSize(width: 920, height: 580)
        }
    }
}

/// Where the quick panel emerges from when it opens.
nonisolated enum PanelOrigin: String, CaseIterable, Identifiable, Sendable {
    case top, bottom, left, right, center
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .top: "rectangle.tophalf.inset.filled"
        case .bottom: "rectangle.bottomhalf.inset.filled"
        case .left: "rectangle.lefthalf.inset.filled"
        case .right: "rectangle.righthalf.inset.filled"
        case .center: "rectangle.center.inset.filled"
        }
    }
    /// One line for Settings: what the user will see.
    var summary: String {
        switch self {
        case .top: "Drops down from under the menu bar."
        case .bottom: "Rises from just above the Dock."
        case .left: "Slides out from the left edge."
        case .right: "Slides out from the right edge."
        case .center: "Fades up in the middle of the screen."
        }
    }
}

nonisolated struct AppTransformRule: Codable, Hashable, Identifiable, Sendable {
    var app: AppRef
    var transform: Transform
    var id: String { app.bundleID }
}

nonisolated struct CustomPrompt: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var prompt: String
}

/// UserDefaults-backed settings. Secrets (the Claude API key) never live here — see `Keychain`.
@Observable
final class Preferences {
    nonisolated enum Key {
        static let maxItems = "maxItems"
        static let maxAgeDays = "maxAgeDays"            // legacy, migrated into maxAgeMinutes
        static let maxAgeMinutes = "maxAgeMinutes"
        static let isPaused = "isPaused"
        static let appearance = "appearance"
        static let panelSize = "panelSize"
        static let panelOrigin = "panelOrigin"
        static let panelFrameSize = "panelFrameSize"
        static let panelPositions = "panelPositions"
        static let ignoredApps = "ignoredApps"
        static let appTransforms = "appTransforms"
        static let claudeModel = "claudeModel"          // legacy, migrated into aiModels
        static let aiProvider = "aiProvider"
        static let aiModels = "aiModels"
        static let customBaseURL = "customBaseURL"
        static let secretGraceMinutes = "secretGraceMinutes"
        static let secretClearSeconds = "secretClearSeconds"
        static let dedupeVersion = "dedupeVersion"
        static let contextMenuEnabled = "contextMenuEnabled"
        static let contextMenuModifier = "contextMenuModifier"
        static let customPrompts = "customPrompts"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let hasShownPermissions = "hasShownPermissions"
        static let syncDefaultGroupID = "syncDefaultGroupID"
        static let saveFolder = "saveFolder"
        static let confirmGroupSends = "confirmGroupSends"
        static let blockSensitiveGroupSends = "blockSensitiveGroupSends"
        static let restoredSendToGroupDefault = "restoredSendToGroupDefault"
        static let pasteIcon = "pasteIcon"
        static let pasteIconHiddenApps = "pasteIconHiddenApps"
        static let offerToSavePasswords = "offerToSavePasswords"
        static let neverSavePasswordSites = "neverSavePasswordSites"
        static let notificationsEnabled = "notificationsEnabled"
        static let notificationKindsOff = "notificationKindsOff"
        static let mutedNotificationGroups = "mutedNotificationGroups"
    }

    /// 0 means "ask every time".
    static let secretGraceChoices = [0, 1, 5, 15, 60]
    /// 0 means "never clear".
    static let secretClearChoices = [15, 30, 60, 120, 0]
    /// 0 means "keep forever".
    /// Minutes; 0 means "keep forever".
    static let maxAgeChoices = [15, 60, 480, 1_440, 10_080, 43_200, 129_600, 525_600, 0]
    /// 0 means "no count limit" (only the age limit applies).
    static let maxItemChoices = [100, 250, 500, 1000, 2500, 5000, 0]

    static func describeAge(minutes: Int) -> String {
        switch minutes {
        case 0: "Never"
        case ..<60: "\(minutes) minutes"
        case 60: "1 hour"
        case ..<1_440: "\(minutes / 60) hours"
        case 1_440: "1 day"
        default: "\(minutes / 1_440) days"
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    var maxItems: Int { didSet { defaults.set(maxItems, forKey: Key.maxItems) } }
    var maxAgeMinutes: Int { didSet { defaults.set(maxAgeMinutes, forKey: Key.maxAgeMinutes) } }
    var isPaused: Bool { didSet { defaults.set(isPaused, forKey: Key.isPaused) } }
    var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
    /// The old Small/Regular/Large setting, if the user ever picked one: it only seeds the
    /// panel's first size.
    @ObservationIgnored let panelSizeSeed: CGSize?
    /// The panel's size once the user resized it (clamped again on a smaller screen).
    var panelFrameSize: CGSize? {
        didSet {
            if let size = panelFrameSize {
                defaults.set([Double(size.width), Double(size.height)], forKey: Key.panelFrameSize)
            } else {
                defaults.removeObject(forKey: Key.panelFrameSize)
            }
        }
    }
    /// Where the user moved the panel, per screen: its top-left corner in screen points.
    private(set) var panelPositions: [String: CGPoint] {
        didSet { defaults.set(panelPositions.mapValues { [Double($0.x), Double($0.y)] }, forKey: Key.panelPositions) }
    }
    var panelOrigin: PanelOrigin { didSet { defaults.set(panelOrigin.rawValue, forKey: Key.panelOrigin) } }
    /// The icon beside text selected in other apps.
    /// The paste icon in the corner of the focused text field in other apps.
    var pasteIcon: Bool { didSet { defaults.set(pasteIcon, forKey: Key.pasteIcon) } }
    /// Apps where each icon stays away ("Don't Show in …"); hiding one leaves the other.
    var pasteIconHiddenApps: [AppRef] { didSet { store(pasteIconHiddenApps, Key.pasteIconHiddenApps) } }
    /// Offer to save a login whose password was pasted into a password field (Settings → Auth).
    var offerToSavePasswords: Bool { didSet { defaults.set(offerToSavePasswords, forKey: Key.offerToSavePasswords) } }
    /// Sites the user picked "Never for this site" for.
    var neverSavePasswordSites: [NeverSaveSite] { didSet { store(neverSavePasswordSites, Key.neverSavePasswordSites) } }
    var ignoredApps: [AppRef] { didSet { store(ignoredApps, Key.ignoredApps) } }
    var appTransforms: [AppTransformRule] { didSet { store(appTransforms, Key.appTransforms) } }
    var aiProvider: AIProviderKind { didSet { defaults.set(aiProvider.rawValue, forKey: Key.aiProvider) } }
    /// Model per provider, so switching providers keeps each one's choice.
    var aiModels: [String: String] { didSet { defaults.set(aiModels, forKey: Key.aiModels) } }
    var customBaseURL: String { didSet { defaults.set(customBaseURL, forKey: Key.customBaseURL) } }
    var secretGraceMinutes: Int { didSet { defaults.set(secretGraceMinutes, forKey: Key.secretGraceMinutes) } }
    var secretClearSeconds: Int { didSet { defaults.set(secretClearSeconds, forKey: Key.secretClearSeconds) } }
    var dedupeVersion: Int { didSet { defaults.set(dedupeVersion, forKey: Key.dedupeVersion) } }
    var contextMenuEnabled: Bool { didSet { defaults.set(contextMenuEnabled, forKey: Key.contextMenuEnabled) } }
    var contextMenuModifier: ContextMenuModifier {
        didSet { defaults.set(contextMenuModifier.rawValue, forKey: Key.contextMenuModifier) }
    }
    var customPrompts: [CustomPrompt] { didSet { store(customPrompts, Key.customPrompts) } }
    var hasLaunchedBefore: Bool { didSet { defaults.set(hasLaunchedBefore, forKey: Key.hasLaunchedBefore) } }
    var hasShownPermissions: Bool {
        didSet { defaults.set(hasShownPermissions, forKey: Key.hasShownPermissions) }
    }

    /// Group the "send selection" shortcut stores into.
    var syncDefaultGroupID: String? { didSet { defaults.set(syncDefaultGroupID, forKey: Key.syncDefaultGroupID) } }
    /// Where "Save to …" writes items. Stored as a plain path (the app isn't sandboxed).
    var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: Key.saveFolder) } }

    static var defaultSaveFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    }

    /// The send-to-group shortcut waits a few seconds with Undo before anything leaves this Mac.
    var confirmGroupSends: Bool { didSet { defaults.set(confirmGroupSends, forKey: Key.confirmGroupSends) } }
    /// Text that looks like a password, key or code is held back from the send-to-group shortcut.
    var blockSensitiveGroupSends: Bool {
        didSet { defaults.set(blockSensitiveGroupSends, forKey: Key.blockSensitiveGroupSends) }
    }
    /// One-time: ⌥⌘C was the send-to-group default until 1.3; it's opt-in now.
    var restoredSendToGroupDefault: Bool {
        didSet { defaults.set(restoredSendToGroupDefault, forKey: Key.restoredSendToGroupDefault) }
    }
    /// Set when that cleanup removed a shortcut someone had; they're told once, when signed in.

    /// Notifications (Settings → Sync): the master switch, the kinds switched off, muted groups.
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) } }
    var notificationKindsOff: Set<NotificationKind> {
        didSet { defaults.set(notificationKindsOff.map(\.rawValue).sorted(), forKey: Key.notificationKindsOff) }
    }
    var mutedNotificationGroups: Set<String> {
        didSet { defaults.set(mutedNotificationGroups.sorted(), forKey: Key.mutedNotificationGroups) }
    }

    var notificationSettings: NotificationSettings {
        NotificationSettings(enabled: notificationsEnabled,
                             kinds: Set(NotificationKind.allCases).subtracting(notificationKindsOff),
                             mutedGroups: mutedNotificationGroups)
    }

    func notifies(_ kind: NotificationKind) -> Bool { !notificationKindsOff.contains(kind) }

    func setNotifies(_ kind: NotificationKind, _ on: Bool) {
        if on { notificationKindsOff.remove(kind) } else { notificationKindsOff.insert(kind) }
    }

    func isMuted(group id: String) -> Bool { mutedNotificationGroups.contains(id) }

    func setMuted(_ muted: Bool, group id: String) {
        if muted { mutedNotificationGroups.insert(id) } else { mutedNotificationGroups.remove(id) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.maxItems: 500,
            Key.isPaused: false,
            Key.appearance: AppearanceMode.system.rawValue,
            Key.panelOrigin: PanelOrigin.top.rawValue,
            Key.aiProvider: AIProviderKind.claudeCode.rawValue,
            Key.customBaseURL: AIProviderKind.custom.defaultBaseURL,
            Key.secretGraceMinutes: 15,
            Key.secretClearSeconds: 30,
            Key.contextMenuEnabled: true,
            Key.contextMenuModifier: ContextMenuModifier.command.rawValue,
            Key.confirmGroupSends: false,
            Key.pasteIcon: true,
            Key.offerToSavePasswords: true,
            Key.blockSensitiveGroupSends: true,
            Key.notificationsEnabled: true,
        ])
        let storedMax = defaults.integer(forKey: Key.maxItems)
        maxItems = storedMax == 0 ? 0 : max(10, storedMax)
        if defaults.object(forKey: Key.maxAgeMinutes) != nil {
            maxAgeMinutes = max(0, defaults.integer(forKey: Key.maxAgeMinutes))
        } else if defaults.object(forKey: Key.maxAgeDays) != nil {
            maxAgeMinutes = max(0, defaults.integer(forKey: Key.maxAgeDays)) * 1_440
        } else {
            maxAgeMinutes = 43_200   // 30 days
        }
        isPaused = defaults.bool(forKey: Key.isPaused)
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        panelSizeSeed = PanelSize(rawValue: defaults.string(forKey: Key.panelSize) ?? "")?.size
        if let size = defaults.array(forKey: Key.panelFrameSize) as? [Double], size.count == 2 {
            panelFrameSize = CGSize(width: size[0], height: size[1])
        } else {
            panelFrameSize = nil
        }
        panelPositions = (defaults.dictionary(forKey: Key.panelPositions) as? [String: [Double]] ?? [:])
            .compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        panelOrigin = PanelOrigin(rawValue: defaults.string(forKey: Key.panelOrigin) ?? "") ?? .top
        pasteIcon = defaults.bool(forKey: Key.pasteIcon)
        pasteIconHiddenApps = Self.load([AppRef].self, defaults, Key.pasteIconHiddenApps) ?? []
        offerToSavePasswords = defaults.bool(forKey: Key.offerToSavePasswords)
        neverSavePasswordSites = Self.load([NeverSaveSite].self, defaults, Key.neverSavePasswordSites) ?? []
        ignoredApps = Self.load([AppRef].self, defaults, Key.ignoredApps) ?? AppRef.defaultIgnored
        appTransforms = Self.load([AppTransformRule].self, defaults, Key.appTransforms) ?? []
        aiProvider = AIProviderKind(rawValue: defaults.string(forKey: Key.aiProvider) ?? "") ?? .claudeCode
        var models = defaults.dictionary(forKey: Key.aiModels) as? [String: String] ?? [:]
        if models[AIProviderKind.anthropic.rawValue] == nil, let legacy = defaults.string(forKey: Key.claudeModel) {
            models[AIProviderKind.anthropic.rawValue] = legacy
        }
        aiModels = models
        customBaseURL = defaults.string(forKey: Key.customBaseURL) ?? AIProviderKind.custom.defaultBaseURL
        secretGraceMinutes = max(0, defaults.integer(forKey: Key.secretGraceMinutes))
        secretClearSeconds = max(0, defaults.integer(forKey: Key.secretClearSeconds))
        dedupeVersion = defaults.integer(forKey: Key.dedupeVersion)
        contextMenuEnabled = defaults.bool(forKey: Key.contextMenuEnabled)
        contextMenuModifier = ContextMenuModifier(rawValue: defaults.string(forKey: Key.contextMenuModifier) ?? "") ?? .command
        customPrompts = Self.load([CustomPrompt].self, defaults, Key.customPrompts) ?? []
        hasLaunchedBefore = defaults.bool(forKey: Key.hasLaunchedBefore)
        hasShownPermissions = defaults.bool(forKey: Key.hasShownPermissions)
        syncDefaultGroupID = defaults.string(forKey: Key.syncDefaultGroupID)
        saveFolder = defaults.string(forKey: Key.saveFolder).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? Self.defaultSaveFolder
        confirmGroupSends = defaults.bool(forKey: Key.confirmGroupSends)
        blockSensitiveGroupSends = defaults.bool(forKey: Key.blockSensitiveGroupSends)
        restoredSendToGroupDefault = defaults.bool(forKey: Key.restoredSendToGroupDefault)
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        notificationKindsOff = Set((defaults.stringArray(forKey: Key.notificationKindsOff) ?? []).compactMap(NotificationKind.init(rawValue:)))
        mutedNotificationGroups = Set(defaults.stringArray(forKey: Key.mutedNotificationGroups) ?? [])
    }

    /// The save folder's name as Finder shows it ("Downloads", "Desktop").
    var saveFolderName: String {
        FileManager.default.displayName(atPath: saveFolder.path)
    }

    var maxAge: TimeInterval? {
        maxAgeMinutes > 0 ? TimeInterval(maxAgeMinutes) * 60 : nil
    }

    /// The selected model for the active provider (falls back to the provider's default).
    var aiModel: String {
        get { aiModels[aiProvider.rawValue] ?? aiProvider.defaultModel }
        set { aiModels[aiProvider.rawValue] = newValue }
    }

    var ignoredBundleIDs: Set<String> { Set(ignoredApps.map(\.bundleID)) }

    func panelPosition(forScreen key: String) -> CGPoint? { panelPositions[key] }

    func setPanelPosition(_ topLeft: CGPoint, forScreen key: String) {
        if panelPositions[key] != topLeft { panelPositions[key] = topLeft }
    }

    /// Settings → Reset Position: the panel opens where its origin setting puts it again.
    func resetPanelPositions() {
        panelPositions = [:]
    }

    func defaultTransform(for bundleID: String?) -> Transform? {
        guard let bundleID else { return nil }
        return appTransforms.first { $0.app.bundleID == bundleID }?.transform
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ defaults: UserDefaults, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
