import SwiftUI

/// Leading badge for a panel row: what the item is at a glance (a color shows itself, a link a
/// chain, a key a shield). Images keep their thumbnail and files their icon.
struct ContentBadge: View {
    enum Kind {
        case clip(ClipItem)
        case snippet
        case secret
    }

    let kind: Kind
    var isSelected = false
    var size: CGFloat = 30

    var body: some View {
        Group {
            switch kind {
            case .clip(let item) where item.kind == .image || item.kind == .file:
                ClipIconView(item: item, size: size)
            case .clip(let item):
                switch ClipContentCache.content(of: item) {
                case .color(let color):
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .fill(color.swiftUIColor)
                        .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                            .strokeBorder(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.primary.opacity(0.12)),
                                          lineWidth: isSelected ? 1.5 : 1))
                case let content:
                    symbol(Self.symbol(for: content), tint: Self.tint(for: content))
                }
            case .snippet:
                symbol("text.badge.star", tint: .pink)
            case .secret:
                symbol("key.fill", tint: nil)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// A nil tint is the neutral gray tile used for plain text and secrets.
    private func symbol(_ name: String, tint: Color?) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .frame(width: size, height: size)
            .background(isSelected ? AnyShapeStyle(.white.opacity(0.22))
                        : tint.map { AnyShapeStyle($0.opacity(0.14)) } ?? AnyShapeStyle(Color.primary.opacity(0.08)),
                        in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }

    static func symbol(for content: ClipContent) -> String {
        switch content {
        case .plain: "text.alignleft"
        case .color: "paintpalette"
        case .link: "link"
        case .email: "envelope"
        case .phone: "phone"
        case .json: "curlybraces"
        case .command: "terminal"
        case .sensitive: "exclamationmark.shield"
        }
    }

    static func tint(for content: ClipContent) -> Color? {
        switch content {
        case .plain, .color: nil
        case .link: .blue
        case .email, .phone: .teal
        case .json, .command: .indigo
        case .sensitive: .orange
        }
    }
}

extension RGBColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: alpha)
    }
}

/// Text with the characters a search matched marked, for list rows.
enum SearchHighlight {
    static func text(_ string: String, query: String, onAccent: Bool) -> AttributedString {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let indices = FuzzyMatcher.matchedIndices(query: q, in: string), !indices.isEmpty else {
            return AttributedString(string)
        }
        let hits = Set(indices)
        var result = AttributedString()
        var run = ""
        var runIsHit = false
        func flush() {
            guard !run.isEmpty else { return }
            var part = AttributedString(run)
            if runIsHit {
                part.backgroundColor = onAccent ? .white.opacity(0.3) : .yellow.opacity(0.45)
                part.inlinePresentationIntent = .stronglyEmphasized
            }
            result += part
            run = ""
        }
        for (offset, character) in string.enumerated() {
            let isHit = hits.contains(offset)
            if isHit != runIsHit { flush(); runIsHit = isHit }
            run.append(character)
        }
        flush()
        return result
    }
}
