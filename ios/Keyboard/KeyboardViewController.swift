import UIKit
import SwiftUI

final class KeyboardViewController: UIInputViewController {

    private var hostingController: UIHostingController<MicKeyboardView>?
    private let model = KeyboardLiveStatusModel()
    private var statusObserver: NSObjectProtocol?
    private var resultObserver: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let micView = MicKeyboardView(
            model: model,
            onTap: { [weak self] in
                self?.openContainer(language: SharedSettings.shared.language)
            },
            onSwitch: { [weak self] in
                self?.advanceToNextInputMode()
            }
        )
        let host = UIHostingController(rootView: micView)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.hostingController = host

        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 270)
        heightConstraint.priority = UILayoutPriority(999)
        heightConstraint.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.hasFullAccess = hasFullAccess

        statusObserver = AppGroupBridge.observe(AppGroupBridge.didUpdateStatusNotification) { [weak self] in
            guard let self else { return }
            if let status = AppGroupBridge.readStatus() {
                self.model.phase = status.phase
                self.model.partialText = status.partialText ?? ""
                self.model.audioLevel = status.audioLevel
                self.model.errorMessage = status.errorMessage
            }
        }

        resultObserver = AppGroupBridge.observe(AppGroupBridge.didFinishResultNotification) { [weak self] in
            self?.consumeResult()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Releasing the tokens triggers CFNotificationCenterRemoveObserver in DarwinToken.deinit.
        statusObserver = nil
        resultObserver = nil
    }

    override func textWillChange(_ textInput: (any UITextInput)?) {}

    override func textDidChange(_ textInput: (any UITextInput)?) {
        // Update return-key appearance based on host field's returnKeyType.
    }

    // MARK: - Container bounce

    /// Writes a RecordRequest to the App Group and then opens the container app
    /// via the `voiceinput://record` URL scheme. Because keyboard extensions cannot
    /// call `UIApplication.shared.open(_:)` directly, we walk up the UIResponder
    /// chain to find a responder that implements `openURL:` — the same pattern
    /// documented by iFlytek and used in Gboard.
    func openContainer(language: String) {
        guard hasFullAccess else { return }

        let id = UUID()
        AppGroupBridge.writeRequest(.init(
            id: id,
            createdAt: Date(),
            language: language,
            hostBundleID: nil
        ))
        AppGroupBridge.clearResult()

        guard let url = URL(string: "voiceinput://record?lang=\(language)&id=\(id.uuidString)") else { return }

        model.phase = .starting
        model.partialText = ""
        model.errorMessage = nil

        // Walk the responder chain looking for a UIResponder that responds to openURL:.
        // UIApplication (which sits at the top of the chain) is the actual responder
        // that handles this selector, but we cannot reference UIApplication.shared
        // inside an extension. The perform(:with:) call dispatches to it safely.
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let r = responder {
            if r.responds(to: selector) {
                _ = r.perform(selector, with: url)
                return
            }
            responder = r.next
        }
    }

    // MARK: - Result consumption

    func consumeResult() {
        guard let result = AppGroupBridge.readResult() else { return }
        textDocumentProxy.insertText(result.text)
        AppGroupBridge.clearResult()
        model.phase = .done
        model.partialText = ""
    }
}
