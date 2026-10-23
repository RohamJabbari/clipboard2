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
        static let hasShownSendToGroupWarning = "hasShownSendToGroupWarning"
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
    var panelSize: PanelSize { didSet { defaults.set(panelSize.rawValue, forKey: Key.panelSize) } }
    var panelOrigin: PanelOrigin { didSet { defaults.set(panelOrigin.rawValue, forKey: Key.panelOrigin) } }
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
    var hasShownSendToGroupWarning: Bool {
        didSet { defaults.set(hasShownSendToGroupWarning, forKey: Key.hasShownSendToGroupWarning) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.maxItems: 500,
            Key.isPaused: false,
            Key.appearance: AppearanceMode.system.rawValue,
            Key.panelSize: PanelSize.regular.rawValue,
            Key.panelOrigin: PanelOrigin.top.rawValue,
            Key.aiProvider: AIProviderKind.claudeCode.rawValue,
            Key.customBaseURL: AIProviderKind.custom.defaultBaseURL,
            Key.secretGraceMinutes: 15,
            Key.secretClearSeconds: 30,
            Key.contextMenuEnabled: true,
            Key.contextMenuModifier: ContextMenuModifier.command.rawValue,
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
        panelSize = PanelSize(rawValue: defaults.string(forKey: Key.panelSize) ?? "") ?? .regular
        panelOrigin = PanelOrigin(rawValue: defaults.string(forKey: Key.panelOrigin) ?? "") ?? .top
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
        hasShownSendToGroupWarning = defaults.bool(forKey: Key.hasShownSendToGroupWarning)
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
