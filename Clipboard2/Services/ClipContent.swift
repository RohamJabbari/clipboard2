import Foundation

/// What a text clip is, so its row gets a fitting icon and its preview fitting tools: a color
/// gets a swatch, a link its address, JSON is formatted, a credential is hidden. Pure.
nonisolated enum ClipContent: Equatable, Sendable {
    case plain
    case color(RGBColor)
    case link(URL)
    case email(String)
    case phone(String)
    /// Pretty-printed, keys in their original order.
    case json(String)
    case command
    case sensitive(SensitiveText.Kind)

    /// The type line in the preview ("Link", "JSON"…); nil for plain text.
    var title: String? {
        switch self {
        case .plain: nil
        case .color: "Color"
        case .link: "Link"
        case .email: "Email address"
        case .phone: "Phone number"
        case .json: "JSON"
        case .command: "Shell command"
        case .sensitive(let kind): kind.shortName
        }
    }

    /// First words of single-line shell commands people copy from docs and chats.
    private static let commandWords: Set<String> = [
        "brew", "git", "npm", "npx", "yarn", "pnpm", "bun", "cd", "ls", "sudo", "curl", "wget",
        "docker", "kubectl", "make", "xcodebuild", "xcrun", "swift", "python", "python3", "pip",
        "pip3", "open", "cat", "echo", "ssh", "scp", "rm", "cp", "mv", "mkdir", "chmod", "chown",
        "export", "defaults", "killall", "launchctl", "gh", "go", "cargo", "rustup", "node",
    ]

    static func classify(_ text: String) -> ClipContent {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .plain }
        if let kind = SensitiveText.detect(value) { return .sensitive(kind) }
        let singleLine = !value.contains(where: \.isNewline)
        if singleLine, let color = RGBColor(parsing: value) { return .color(color) }
        if !value.contains(where: \.isWhitespace) {
            if let url = URL(string: value), let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https", url.host() != nil {
                return .link(url)
            }
            if isEmail(value) { return .email(value) }
        }
        if let first = value.first, let last = value.last, "{[".contains(first), "}]".contains(last),
           value.count <= 200_000, let pretty = Transform.jsonPrettify.apply(value) {
            return .json(pretty)
        }
        if isPhone(value) { return .phone(value) }
        if singleLine, value.count <= 400, isCommand(value) { return .command }
        return .plain
    }

    private static func isEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, value.count <= 254 else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    /// International (+43 …) or bracketed numbers; bare digit runs and dates are left alone.
    private static func isPhone(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789 +-().")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        let digits = value.filter(\.isNumber).count
        guard (7...15).contains(digits) else { return false }
        return value.hasPrefix("+") || value.contains("(") || (value.contains(" ") && digits >= 9)
    }

    private static func isCommand(_ value: String) -> Bool {
        if value.hasPrefix("$ ") { return true }
        guard let first = value.split(separator: " ").first else { return false }
        return commandWords.contains(String(first)) && value.contains(" ")
    }
}

/// An sRGB color read from `#RGB`, `#RRGGBB`, `#RRGGBBAA` or `rgb()`/`rgba()`.
nonisolated struct RGBColor: Equatable, Sendable {
    var red: Int
    var green: Int
    var blue: Int
    var alpha: Double = 1

    init(red: Int, green: Int, blue: Int, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(parsing text: String) {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") {
            let hex = Array(value.dropFirst())
            guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
            let digits = hex.count <= 4 ? hex.flatMap { [$0, $0] } : hex
            let bytes = stride(from: 0, to: digits.count, by: 2).compactMap { Int(String(digits[$0...$0 + 1]), radix: 16) }
            self.init(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes.count == 4 ? Double(bytes[3]) / 255 : 1)
            return
        }
        let lower = value.lowercased()
        guard lower.hasPrefix("rgb"), let open = lower.firstIndex(of: "("), lower.hasSuffix(")") else { return nil }
        let numbers = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 3 || numbers.count == 4, numbers.prefix(3).allSatisfy({ (0...255).contains($0) }) else { return nil }
        self.init(red: Int(numbers[0]), green: Int(numbers[1]), blue: Int(numbers[2]), alpha: numbers.count == 4 ? min(max(numbers[3], 0), 1) : 1)
    }

    var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue) + (alpha < 1 ? String(format: "%02X", Int((alpha * 255).rounded())) : "")
    }

    var rgb: String { "\(red) \(green) \(blue)" }
    var cssRGB: String { "rgb(\(red), \(green), \(blue))" }

    /// Hue in degrees, saturation and lightness in percent.
    var hsl: String {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        let l = (maxC + minC) / 2
        var h = 0.0, s = 0.0
        if maxC != minC {
            let d = maxC - minC
            s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
            switch maxC {
            case r: h = (g - b) / d + (g < b ? 6 : 0)
            case g: h = (b - r) / d + 2
            default: h = (r - g) / d + 4
            }
            h *= 60
        }
        return "\(Int(h.rounded()))° \(Int((s * 100).rounded()))% \(Int((l * 100).rounded()))%"
    }

    /// WCAG contrast ratio against another color, 1…21.
    func contrast(with other: RGBColor) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private var luminance: Double {
        func channel(_ value: Int) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    static let white = RGBColor(red: 255, green: 255, blue: 255)
    static let black = RGBColor(red: 0, green: 0, blue: 0)
}

/// Rows ask for their content on every render; classifying once per content hash keeps that cheap.
enum ClipContentCache {
    private static var cache: [String: ClipContent] = [:]

    static func content(of item: ClipItem) -> ClipContent {
        guard item.kind.isTextual else { return .plain }
        let key = item.contentHash.isEmpty ? item.id.uuidString : item.contentHash
        if let cached = cache[key] { return cached }
        let content = ClipContent.classify(item.text)
        if cache.count > 2_000 { cache.removeAll() }
        cache[key] = content
        return content
    }
}
