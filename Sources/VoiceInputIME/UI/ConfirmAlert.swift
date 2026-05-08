import Cocoa

enum ConfirmAlert {
    /// Shows a synchronous NSAlert. Returns true if the user clicked the
    /// destructive action button.
    static func destructive(title: String, message: String, confirmTitle: String = "Delete") -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        // Make the first button (the destructive action) visually distinct.
        if let btn = alert.buttons.first {
            btn.hasDestructiveAction = true
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
