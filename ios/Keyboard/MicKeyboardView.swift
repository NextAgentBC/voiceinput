import SwiftUI
import UIKit
import AVFoundation

/// SwiftUI view presented inside the keyboard extension.
///
/// Layout: one WeChat-style "hold to talk" bar filling the width, small globe key on the
/// left for switching keyboards. No space/return/delete — this keyboard is pure dictation.
struct MicKeyboardView: View {
    let hasFullAccess: Bool
    let onInsert: (String) -> Void
    let onDeleteBackward: () -> Void        // kept for API compat; unused in bar mode
    let onSpace: () -> Void                 // kept for API compat; unused in bar mode
    let onReturn: () -> Void                // kept for API compat; unused in bar mode
    let onNextKeyboard: () -> Void

    @StateObject private var recorder = KeyboardRecorder()

    var body: some View {
        HStack(spacing: 10) {
            PressAndHoldBar(
                isRecording: recorder.state == .recording,
                label: barLabel,
                onPress: { recorder.startIfNeeded() },
                onRelease: {
                    recorder.stopAndTranscribe { text in
                        guard !text.isEmpty else { return }
                        let out = SharedSettings.autoInsertSpace ? text + " " : text
                        onInsert(out)
                    }
                }
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var barLabel: String {
        switch recorder.state {
        case .idle:           return "Hold to Talk"
        case .requestingAuth: return "Requesting permission…"
        case .recording:      return "Release to Send"
        case .transcribing:   return "Transcribing…"
        case .error(let msg): return msg
        }
    }

    private var globeButton: some View {
        Button(action: onNextKeyboard) {
            Image(systemName: "globe")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.primary)
                .frame(width: 36, height: 44)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// UIKit-backed horizontal press-and-hold bar. Mirrors the WeChat "按住说话" UX.
struct PressAndHoldBar: UIViewRepresentable {
    let isRecording: Bool
    let label: String
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> BarView {
        let v = BarView()
        v.setTitle(label)
        v.setRecording(isRecording, animated: false)

        let press = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        v.addGestureRecognizer(press)
        return v
    }

    func updateUIView(_ v: BarView, context: Context) {
        v.setTitle(label)
        v.setRecording(isRecording, animated: true)
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: PressAndHoldBar
        init(_ parent: PressAndHoldBar) { self.parent = parent }

        @objc func handle(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                parent.onPress()
            case .ended, .cancelled, .failed:
                parent.onRelease()
            default:
                break
            }
        }
    }

    /// The actual UIKit view — keeps title + state rendering in one place so SwiftUI's
    /// update path doesn't churn the entire view hierarchy on every press.
    final class BarView: UIView {
        private let label = UILabel()
        private let icon = UIImageView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        required init?(coder: NSCoder) { fatalError() }

        private func setup() {
            backgroundColor = .secondarySystemBackground
            layer.cornerRadius = 10

            label.textAlignment = .center
            label.font = .systemFont(ofSize: 16, weight: .semibold)
            label.textColor = .label

            icon.image = UIImage(systemName: "mic.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
            icon.tintColor = .label
            icon.contentMode = .scaleAspectFit

            let stack = UIStackView(arrangedSubviews: [icon, label])
            stack.axis = .horizontal
            stack.spacing = 8
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)

            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            ])
        }

        func setTitle(_ text: String) {
            if label.text != text { label.text = text }
        }

        func setRecording(_ recording: Bool, animated: Bool) {
            let bg: UIColor = recording ? .systemRed : .secondarySystemBackground
            let fg: UIColor = recording ? .white : .label
            let apply = { [weak self] in
                guard let self else { return }
                self.backgroundColor = bg
                self.label.textColor = fg
                self.icon.tintColor = fg
                self.transform = recording
                    ? CGAffineTransform(scaleX: 1.02, y: 1.02)
                    : .identity
            }
            if animated {
                UIView.animate(withDuration: 0.15, animations: apply)
            } else {
                apply()
            }
        }
    }
}

// Old circular mic kept only so other code that imports it still builds; unused in bar mode.
struct PressAndHoldMic: UIViewRepresentable {
    let isRecording: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    func makeCoordinator() -> NSObject { NSObject() }
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {}
}
