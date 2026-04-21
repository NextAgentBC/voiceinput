import UIKit
import SwiftUI

/// Root view controller for the VoiceInput custom keyboard extension.
///
/// Hosts a SwiftUI mic UI (`MicKeyboardView`) and wires the "insert text" / "delete" /
/// "switch keyboard" callbacks to `UITextDocumentProxy`. When the user holds the mic button,
/// STT begins; on release, the transcribed text is inserted into the active text field.
final class KeyboardViewController: UIInputViewController {

    private var hostingController: UIHostingController<MicKeyboardView>?
    private var heightConstraint: NSLayoutConstraint?
    private let keyboardHeight: CGFloat = 80

    override func viewDidLoad() {
        super.viewDidLoad()

        // Set a visible background so we can tell the view is there even if SwiftUI hiccups.
        self.view.backgroundColor = .systemBackground

        setupUI()
        setupHeightConstraint()
    }

    private func setupHeightConstraint() {
        // Create once, reuse. `.required` priority on the expression used for inputView so
        // iOS gives us the space we need; if UIKit objects we lower to .defaultHigh.
        let c = self.view.heightAnchor.constraint(equalToConstant: keyboardHeight)
        c.priority = UILayoutPriority(999)
        c.isActive = true
        self.heightConstraint = c
    }

    private func setupUI() {
        let view = MicKeyboardView(
            hasFullAccess: self.hasFullAccess,
            onInsert: { [weak self] text in
                self?.textDocumentProxy.insertText(text)
            },
            onDeleteBackward: { [weak self] in
                self?.textDocumentProxy.deleteBackward()
            },
            onSpace: { [weak self] in
                self?.textDocumentProxy.insertText(" ")
            },
            onReturn: { [weak self] in
                self?.textDocumentProxy.insertText("\n")
            },
            onNextKeyboard: { [weak self] in
                self?.advanceToNextInputMode()
            }
        )

        let host = UIHostingController(rootView: view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addChild(host)
        self.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.hostingController = host
    }
}
