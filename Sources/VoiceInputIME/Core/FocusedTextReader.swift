import Cocoa
import ApplicationServices
import os.log

private let axLog = Logger(subsystem: "com.voiceinput.app", category: "FocusedText")

/// Reads the current contents of the focused text input via the Accessibility
/// API. Not every app cooperates — WebView-based clients (Slack, some Lark
/// surfaces) tend to return nil. Callers must tolerate failure.
enum FocusedTextReader {

    /// Return the text in the currently focused UI element, or nil if unavailable.
    static func read() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let el = focused else { return nil }
        let element = el as! AXUIElement

        // Try kAXValue first — covers most native text fields.
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let str = value as? String {
            return str
        }

        // Fallback: selected text gives context when kAXValue fails.
        var selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
           let str = selected as? String, !str.isEmpty {
            return str
        }

        axLog.debug("Focused element did not expose text via AX")
        return nil
    }
}
