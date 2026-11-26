import Foundation

nonisolated enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text
    case richText
    case image
    case file

    var displayName: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich Text"
        case .image: "Image"
        case .file: "File"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .image: "photo"
        case .file: "doc"
        }
    }

    var isTextual: Bool { self == .text || self == .richText }
}
