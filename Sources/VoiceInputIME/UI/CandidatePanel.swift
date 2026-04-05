import Cocoa
import SwiftUI

/// Candidate selection panel for when multiple corrections are available.
/// Shows near the cursor as a floating panel with numbered options.
final class CandidatePanel: NSPanel {
    private var candidates: [String] = []
    private var onSelect: ((String) -> Void)?
    private var hostingView: NSHostingView<CandidateListView>?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show candidates near the current cursor position.
    /// User presses 1-9 to select, Escape to dismiss, or Enter for first option.
    func show(candidates: [String], near point: NSPoint, onSelect: @escaping (String) -> Void) {
        self.candidates = candidates
        self.onSelect = onSelect

        let view = CandidateListView(candidates: candidates)
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        contentView = hosting
        self.hostingView = hosting

        // Size based on content
        let height = CGFloat(candidates.count) * 28 + 12
        let width: CGFloat = 320
        let frame = NSRect(x: point.x, y: point.y - height, width: width, height: height)
        setFrame(frame, display: true)

        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }

    /// Handle key press for candidate selection. Returns true if handled.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }

        // Number keys 1-9
        if event.type == .keyDown {
            let key = event.charactersIgnoringModifiers ?? ""

            if let num = Int(key), num >= 1, num <= candidates.count {
                let selected = candidates[num - 1]
                onSelect?(selected)
                dismiss()
                return true
            }

            // Enter = select first
            if event.keyCode == 36 && !candidates.isEmpty {
                onSelect?(candidates[0])
                dismiss()
                return true
            }

            // Escape = dismiss
            if event.keyCode == 53 {
                dismiss()
                return true
            }
        }

        return false
    }
}

// MARK: - SwiftUI View

struct CandidateListView: View {
    let candidates: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(candidates.enumerated()), id: \.offset) { index, text in
                HStack(spacing: 8) {
                    Text("\(index + 1).")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 20, alignment: .trailing)

                    Text(text)
                        .font(.system(size: 14))
                        .foregroundColor(.primary)

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
        )
    }
}
