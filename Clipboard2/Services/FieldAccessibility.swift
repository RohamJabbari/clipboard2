import AppKit
import ApplicationServices

/// An Accessibility element that can cross to a background task (AX calls are thread-safe).
nonisolated struct AXElement: @unchecked Sendable, Hashable {
    let raw: AXUIElement

    static func == (lhs: AXElement, rhs: AXElement) -> Bool { CFEqual(lhs.raw, rhs.raw) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(raw)) }
}

/// Reading forms in other apps for Fill (docs/features/auth-autofill.md → Phase 2): the focused
/// field's kind, the fields around it, labels, and the page URL. Values are read only where Fill
/// needs them (whether a field is empty, the username above a new password).
nonisolated enum FieldAX {
    static let secureSubrole = kAXSecureTextFieldSubrole as String
    private static let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String,
                                                 kAXComboBoxRole as String, "AXSecureTextField", "AXSearchField"]

    static func application(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    static func focusedElement(pid: pid_t) -> AXElement? {
        element(application(pid), kAXFocusedUIElementAttribute).map(AXElement.init)
    }

    // MARK: Fields

    static func isSecure(_ element: AXElement) -> Bool {
        let subrole: String? = value(element.raw, kAXSubroleAttribute)
        let role: String? = value(element.raw, kAXRoleAttribute)
        return subrole == secureSubrole || role == "AXSecureTextField"
    }

    static func isTextField(_ element: AXElement) -> Bool {
        let role: String? = value(element.raw, kAXRoleAttribute)
        guard let role, textRoles.contains(role) else { return false }
        let subrole: String? = value(element.raw, kAXSubroleAttribute)
        return subrole != "AXSearchField" && role != "AXSearchField"
    }

    /// The focused field in `pid`, and the field after it on the page.
    static func focusedFieldKind(pid: pid_t) -> FocusedFieldKind {
        guard let focused = focusedElement(pid: pid), isTextField(focused) else { return .unknown }
        if isSecure(focused) { return .secure }
        let fields = formFields(around: focused)
        guard let index = fields.firstIndex(of: focused) else { return .text(nextIsSecure: false) }
        let next = fields.index(after: index)
        return .text(nextIsSecure: next < fields.endIndex && isSecure(fields[next]))
    }

    /// The web area (or, outside browsers, the window) a field is in.
    static func container(of element: AXElement) -> AXElement? {
        var current = element.raw
        var window: AXUIElement?
        for _ in 0..<60 {
            guard let parent = Self.element(current, kAXParentAttribute) else { break }
            let role: String? = value(parent, kAXRoleAttribute)
            if role == "AXWebArea" { return AXElement(raw: parent) }
            if role == kAXWindowRole as String { window = parent; break }
            current = parent
        }
        return window.map(AXElement.init)
    }

    /// Every text and password field in the same web area (or window), in document order.
    static func formFields(around element: AXElement) -> [AXElement] {
        guard let container = container(of: element) else { return [element] }
        let found = searchTextFields(in: container) ?? traverseTextFields(in: container)
        return found.contains(element) ? found : found + [element]
    }

    /// Safari and Chromium answer VoiceOver's search, which is far quicker than walking the tree.
    private static func searchTextFields(in container: AXElement) -> [AXElement]? {
        let predicate: [String: Any] = [
            "AXSearchKey": "AXTextFieldSearchKey",
            "AXResultsLimit": 200,
            "AXDirection": "AXDirectionNext",
            "AXVisibleOnly": false,
            "AXImmediateDescendantsOnly": false,
        ]
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(container.raw, "AXUIElementsForSearchPredicate" as CFString,
                                                         predicate as CFDictionary, &result) == .success,
              let elements = result as? [AXUIElement], !elements.isEmpty else { return nil }
        return elements.map(AXElement.init).filter(isTextField)
    }

    private static func traverseTextFields(in container: AXElement, limit: Int = 2_500) -> [AXElement] {
        var found: [AXElement] = []
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) {
            guard visited < limit, depth < 40 else { return }
            visited += 1
            let wrapped = AXElement(raw: element)
            if isTextField(wrapped) {
                found.append(wrapped)
                return
            }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                  let children = children as? [AXUIElement] else { return }
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(container.raw, depth: 0)
        return found
    }

    /// The second password field after this one (a "confirm password" field), if any.
    static func confirmField(after element: AXElement) -> AXElement? {
        let fields = formFields(around: element)
        guard let index = fields.firstIndex(of: element) else { return nil }
        return fields[fields.index(after: index)...].first(where: isSecure)
    }

    /// The nearest text field above a password field: what's typed there is the username.
    static func usernameAbove(_ element: AXElement) -> String? {
        let fields = formFields(around: element)
        guard let index = fields.firstIndex(of: element) else { return nil }
        let top = frame(of: element)?.minY
        for field in fields[..<index].reversed() where !isSecure(field) {
            if let top, let other = frame(of: field), other.minY > top + 1 { continue }   // below it
            let text: String? = value(field.raw, kAXValueAttribute)
            if let text = SecretExtras.cleanUsername(text) { return text }
        }
        return nil
    }

    /// Label, placeholder, identifier and help: what a field's kind is guessed from.
    static func hints(of element: AXElement) -> [String] {
        var hints: [String] = []
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute,
                          kAXIdentifierAttribute, "AXDOMIdentifier", kAXHelpAttribute] {
            if let text: String = value(element.raw, attribute as String), !text.isEmpty { hints.append(text) }
        }
        if let title = Self.element(element.raw, kAXTitleUIElementAttribute) {
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let text: String = value(title, attribute as String), !text.isEmpty { hints.append(text) }
            }
        }
        if let classes: [String] = value(element.raw, "AXDOMClassList") { hints += classes }
        return hints
    }

    /// The field waits for a one-time code (OneTimeCodeField): its label, or a row of digit boxes.
    static func looksLikeOneTimeCode(_ element: AXElement) -> Bool {
        let width = frame(of: element)?.width
        let siblingWidths = width.map { $0 <= 64 ? nearbyTextFieldWidths(element) : [] } ?? []
        return OneTimeCodeField.matches(hints: hints(of: element), width: width, siblingWidths: siblingWidths)
    }

    /// Widths of the text fields around a narrow one: under its parent, or (boxes each wrapped in
    /// their own element) under its grandparent, one level down. A few dozen elements at most.
    private static func nearbyTextFieldWidths(_ element: AXElement) -> [CGFloat] {
        var ancestor = element.raw
        for _ in 0..<2 {
            guard let parent = Self.element(ancestor, kAXParentAttribute) else { break }
            ancestor = parent
            var fields: [AXElement] = []
            var queue: [(AXUIElement, Int)] = [(parent, 0)]
            var visited = 0
            while !queue.isEmpty, visited < 40 {
                let (node, depth) = queue.removeFirst()
                visited += 1
                guard let children: [AXUIElement] = value(node, kAXChildrenAttribute) else { continue }
                for child in children.prefix(24) {
                    let candidate = AXElement(raw: child)
                    if isTextField(candidate) {
                        fields.append(candidate)
                    } else if depth < 1 {
                        queue.append((child, depth + 1))
                    }
                }
            }
            if fields.count >= 4 { return fields.compactMap { frame(of: $0)?.width } }
        }
        return []
    }

    static func isEmpty(_ element: AXElement) -> Bool {
        let text: String? = value(element.raw, kAXValueAttribute)
        return text?.isEmpty ?? true
    }

    @discardableResult
    static func focus(_ element: AXElement) -> Bool {
        AXUIElementSetAttributeValue(element.raw, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    @discardableResult
    static func setValue(_ text: String, of element: AXElement) -> Bool {
        AXUIElementSetAttributeValue(element.raw, kAXValueAttribute as CFString, text as CFString) == .success
    }

    // MARK: Page URL

    /// The page the browser's front window shows: its source domain. Nil outside browsers.
    static func pageDomain(pid: pid_t, bundleID: String?) -> String? {
        guard let browser = BrowserKind.of(bundleID: bundleID) else { return nil }
        let app = application(pid)
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else { return nil }
        if browser == .firefox {
            let title: String? = value(window, kAXTitleAttribute)
            return title.flatMap { SiteMatch.domain(fromWindowTitle: $0) }
        }
        // The focused element's web area first (the page being typed in), then any in the window.
        if let focused = element(app, kAXFocusedUIElementAttribute),
           let area = container(of: AXElement(raw: focused)), let url = url(of: area.raw) {
            return SiteMatch.domain(ofPage: url)
        }
        if let area = find(in: window, maxDepth: 12, where: { role($0) == "AXWebArea" }), let url = url(of: area) {
            return SiteMatch.domain(ofPage: url)
        }
        // The address field: a text field in the toolbar whose value reads like a URL.
        if let field = find(in: window, maxDepth: 10, where: { candidate in
            guard role(candidate) == kAXTextFieldRole as String else { return false }
            let text: String? = value(candidate, kAXValueAttribute)
            return text.map { SiteMatch.domain(ofPage: $0) != nil && !$0.contains(" ") } ?? false
        }), let text: String = value(field, kAXValueAttribute) {
            return SiteMatch.domain(ofPage: text)
        }
        return nil
    }

    private static func url(of element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &raw) == .success, let raw else { return nil }
        if let url = raw as? URL { return url.absoluteString }
        return raw as? String
    }

    private static func role(_ element: AXUIElement) -> String? { value(element, kAXRoleAttribute) }

    /// Breadth-first, so the toolbar and the page are found before deep page content.
    private static func find(in root: AXUIElement, maxDepth: Int, limit: Int = 800,
                             where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < limit {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if matches(element) { return element }
            guard depth < maxDepth else { continue }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                  let children = children as? [AXUIElement] else { continue }
            queue += children.map { ($0, depth + 1) }
        }
        return nil
    }

    // MARK: Helpers

    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func frame(of element: AXElement) -> CGRect? {
        var position = CGPoint.zero, size = CGSize.zero
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element.raw, kAXPositionAttribute as CFString, &raw) == .success, let raw,
              CFGetTypeID(raw) == AXValueGetTypeID(), AXValueGetValue(raw as! AXValue, .cgPoint, &position) else { return nil }
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element.raw, kAXSizeAttribute as CFString, &rawSize) == .success, let rawSize,
              CFGetTypeID(rawSize) == AXValueGetTypeID(), AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
