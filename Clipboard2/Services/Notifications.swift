import AppKit
import Observation
@preconcurrency import UserNotifications

/// The system permission as Settings shows it.
nonisolated enum NotificationPermission: Equatable, Sendable {
    /// Not asked yet: asked the first time something would notify.
    case notDetermined
    case allowed
    case denied
}

/// Posts notifications. The real one is the system's notification center; tests use a fake.
protocol NotificationPosting: AnyObject {
    func permission() async -> NotificationPermission
    /// Asks once; true when allowed.
    func requestPermission() async -> Bool
    func post(_ notification: AppNotification)
}

/// Before the app starts (and in tests): posts nothing.
final class SilentNotifier: NotificationPosting {
    func permission() async -> NotificationPermission { .denied }
    func requestPermission() async -> Bool { false }
    func post(_ notification: AppNotification) {}
}

/// Turns what each sync found into notifications (or, when they're off, the old HUD bubbles for
/// contacts). The first sync after signing in only records what's there.
@Observable
final class NotificationHub {
    /// Refreshed when Settings shows and whenever something is posted.
    private(set) var permission: NotificationPermission = .notDetermined

    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var poster: any NotificationPosting
    /// What the open panel shows, or nil when it's closed.
    @ObservationIgnored var showing: () -> ArrivalPlace? = { nil }
    @ObservationIgnored var showHUD: (String, String) -> Void = { text, symbol in
        HUD.show(text, symbol: symbol, duration: .seconds(3))
    }
    /// A notification was clicked.
    @ObservationIgnored var onOpen: (NotificationTarget) -> Void = { _ in }
    @ObservationIgnored private var baseline: NotificationSnapshot?
    /// Serialises deliveries, so the permission is asked once even when two syncs land together.
    @ObservationIgnored private var delivering: Task<Void, Never>?

    static let baselineKey = "notificationBaseline"

    init(prefs: Preferences, defaults: UserDefaults = .standard, poster: any NotificationPosting = SilentNotifier()) {
        self.prefs = prefs
        self.defaults = defaults
        self.poster = poster
        baseline = defaults.data(forKey: Self.baselineKey).flatMap { try? JSONDecoder().decode(NotificationSnapshot.self, from: $0) }
    }

    /// Signed out: the next session starts by recording.
    func forget() {
        baseline = nil
        defaults.removeObject(forKey: Self.baselineKey)
    }

    /// One sync finished. `recordOnly`: the first after signing in (nothing it finds is news).
    func observe(_ snapshot: NotificationSnapshot, arrivals: [NotificationArrival], me: String, own: OwnActions,
                 recordOnly: Bool) {
        let previous = baseline
        if previous != snapshot {
            baseline = snapshot
            if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: Self.baselineKey) }
        }
        guard !recordOnly, let previous else { return }
        deliver(NotificationDiff.events(from: previous, to: snapshot, arrivals: arrivals, me: me, own: own))
    }

    /// Contact requests not seen before (never on the first look of a session).
    func requestsArrived(_ requests: [ContactRequest]) {
        deliver(NotificationDiff.requestEvents(requests))
    }

    func deliver(_ events: [AppNotification]) {
        guard !events.isEmpty else { return }
        let settings = prefs.notificationSettings
        let showing = showing()
        let previous = delivering
        delivering = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            var allowed: Bool? = self.permission == .notDetermined ? nil : self.permission == .allowed
            var huds: [AppNotification] = []
            for event in events {
                var delivery = NotificationRules.delivery(of: event, settings: settings, allowed: allowed, showing: showing)
                if delivery == .post && allowed == nil {
                    // Asked once, the first time something would notify after updating.
                    allowed = await self.resolvePermission()
                    delivery = NotificationRules.delivery(of: event, settings: settings, allowed: allowed, showing: showing)
                }
                switch delivery {
                case .post: self.poster.post(event)
                case .hud: huds.append(event)
                case .drop: break
                }
            }
            self.showBubble(for: huds)
        }
    }

    /// Waits for everything handed to `deliver` so far (tests).
    func settle() async {
        await delivering?.value
    }

    private func resolvePermission() async -> Bool {
        var current = await poster.permission()
        if current == .notDetermined {
            current = await poster.requestPermission() ? .allowed : .denied
        }
        permission = current
        return current == .allowed
    }

    func refreshPermission() async {
        let current = await poster.permission()
        if current != permission { permission = current }
    }

    /// One bubble at a time: several contact events read as one line.
    private func showBubble(for events: [AppNotification]) {
        guard let first = events.first, let text = first.hudText else { return }
        if events.count == 1 {
            showHUD(text, first.hudSymbol)
        } else {
            showHUD("\(events.count) new things from your contacts", first.hudSymbol)
        }
    }

    /// System Settings → Notifications → Clipboard2.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "at.softmaze.Clippy"
        let urls = ["x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
                    "x-apple.systempreferences:com.apple.preference.notifications"]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}

/// `UNUserNotificationCenter`: posts, and reports clicks. Focus / Do Not Disturb apply by themselves.
final class SystemNotifier: NSObject, NotificationPosting, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let onOpen: (NotificationTarget) -> Void
    nonisolated static let targetKey = "target"

    init(onOpen: @escaping (NotificationTarget) -> Void) {
        self.onOpen = onOpen
        super.init()
        center.delegate = self
    }

    func permission() async -> NotificationPermission {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .allowed
        }
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ notification: AppNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = notification.thread
        if let target = notification.target { content.userInfo = [Self.targetKey: target.encoded] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task { [center] in
            do {
                try await center.add(request)
            } catch {
                Log.sync.error("Couldn't post a notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Shown even while Clipboard2 is the active app (it's a menu bar app; it's often "active").
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let encoded = response.notification.request.content.userInfo[Self.targetKey] as? String
        let isOpen = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        completionHandler()
        guard isOpen, let encoded, let target = NotificationTarget(encoded: encoded) else { return }
        Task { @MainActor in self.onOpen(target) }
    }
}
