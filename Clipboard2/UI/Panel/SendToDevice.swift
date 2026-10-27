import Foundation

/// Another signed-in device that a clip can be sent to ("Send to ‹device›").
nonisolated struct DeviceTarget: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var lastUsedAt: Date?

    /// The other devices, most recently used first; this Mac is never a target.
    static func others(_ devices: [(id: String, name: String, isCurrent: Bool, lastUsedAt: Date?)]) -> [DeviceTarget] {
        var seen = Set<String>()
        return devices
            .filter { !$0.isCurrent && seen.insert($0.id).inserted }
            .map { DeviceTarget(id: $0.id, name: $0.name.isEmpty ? "Unnamed Device" : $0.name, lastUsedAt: $0.lastUsedAt) }
            .sorted {
                switch ($0.lastUsedAt, $1.lastUsedAt) {
                case let (a?, b?) where a != b: a > b
                case (_?, nil): true
                case (nil, _?): false
                default: $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
    }
}

extension DeviceTarget {
    /// The devices the signed-in account can send to right now.
    static func others(in sync: SyncAccount) -> [DeviceTarget] {
        guard sync.isSignedIn else { return [] }
        return others(sync.devices.map { (id: $0.id, name: $0.name, isCurrent: $0.isCurrent, lastUsedAt: $0.lastUsedAt) })
    }
}

extension PanelAction {
    /// "Send to ‹device›" rows: one per other device, for a single saved history item.
    static func sendToDeviceActions(for item: ClipItem?, multiSelecting: Bool, targets: [DeviceTarget]) -> [PanelAction] {
        guard !multiSelecting, let item, !item.isTransient else { return [] }
        return targets.map(PanelAction.sendToDevice)
    }
}
