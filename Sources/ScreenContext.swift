import AppKit
import ApplicationServices

/// What's on screen where you're dictating (the app, the window, the nearby text), read through
/// Accessibility. It is only given to the clean-up step, to pick the right words and tone: a reply
/// in a chat, a code review, an email. Nothing is stored.
enum ScreenContext {
    /// Reads the front window's visible text; up to about 3,000 characters, in under half a second.
    static func capture() -> String {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return "" }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var lines: [String] = []
        var total = 0
        let deadline = Date().addingTimeInterval(0.45)
        let title = (value(root, kAXFocusedWindowAttribute).map { string($0 as! AXUIElement, kAXTitleAttribute) } ?? "") ?? ""

        func add(_ text: String?) {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.count > 1, total < 3000,
                  lines.last != text else { return }
            let piece = String(text.prefix(600))
            lines.append(piece)
            total += piece.count
        }

        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 12, total < 3000, Date() < deadline else { return }
            let role = string(element, kAXRoleAttribute) ?? ""
            // Password boxes are never read.
            if (string(element, kAXSubroleAttribute) ?? "") == "AXSecureTextField" { return }
            if role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField" || role == "AXHeading" {
                add(string(element, kAXValueAttribute) ?? string(element, kAXTitleAttribute))
            }
            guard let children = value(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
            for child in children.prefix(60) { walk(child, depth: depth + 1) }
        }
        if let window = value(root, kAXFocusedWindowAttribute) { walk(window as! AXUIElement, depth: 0) }

        var out = "App: \(app.localizedName ?? "unknown")"
        if !title.isEmpty { out += "\nWindow: \(title)" }
        if !lines.isEmpty { out += "\nText on the screen:\n" + lines.joined(separator: "\n") }
        return out
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }
}
