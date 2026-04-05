import Cocoa
import SwiftUI

final class FloatingPanel: NSPanel {
    private var hostingView: NSHostingView<FloatingContentView>?
    private var visualEffectView: NSVisualEffectView?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 56),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow

        setupVisualEffectView()
        setupHostingView(text: "", audioLevel: 0, isRefining: false, isContinuousMode: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func setupVisualEffectView() {
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 28
        effectView.layer?.masksToBounds = true

        contentView = effectView
        self.visualEffectView = effectView
    }

    private func setupHostingView(text: String, audioLevel: Float, isRefining: Bool, isContinuousMode: Bool) {
        let swiftUIView = FloatingContentView(
            text: text,
            audioLevel: audioLevel,
            isRefining: isRefining,
            isContinuousMode: isContinuousMode
        )
        let hosting = NSHostingView(rootView: swiftUIView)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        if let effectView = visualEffectView {
            // Remove old hosting view if exists
            hostingView?.removeFromSuperview()

            effectView.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.topAnchor.constraint(equalTo: effectView.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
                hosting.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            ])
        }

        self.hostingView = hosting
    }

    func updateContent(text: String, audioLevel: Float, isRefining: Bool = false, isContinuousMode: Bool = false) {
        setupHostingView(text: text, audioLevel: audioLevel, isRefining: isRefining, isContinuousMode: isContinuousMode)

        // Resize panel based on content
        let contentWidth = calculateWidth(for: text, isRefining: isRefining, isContinuousMode: isContinuousMode)
        let newFrame = centeredFrame(width: contentWidth)
        setFrame(newFrame, display: true, animate: false)
    }

    func showWithAnimation() {
        let width = calculateWidth(for: "", isRefining: false)
        let frame = centeredFrame(width: width)
        setFrame(frame, display: true)

        alphaValue = 0
        setFrame(
            NSRect(
                x: frame.origin.x,
                y: frame.origin.y - 20,
                width: frame.width,
                height: frame.height
            ),
            display: true
        )

        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.animator().alphaValue = 1.0
            self.animator().setFrame(frame, display: true)
        })
    }

    func hideWithAnimation(completion: (() -> Void)? = nil) {
        let currentFrame = frame

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true

            // Scale down + fade out
            let scaledFrame = NSRect(
                x: currentFrame.origin.x + currentFrame.width * 0.1,
                y: currentFrame.origin.y + currentFrame.height * 0.1,
                width: currentFrame.width * 0.8,
                height: currentFrame.height * 0.8
            )
            self.animator().setFrame(scaledFrame, display: true)
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
            self.alphaValue = 1.0
            completion?()
        })
    }

    private func calculateWidth(for text: String, isRefining: Bool, isContinuousMode: Bool = false) -> CGFloat {
        let displayText = isRefining ? "Refining..." : (text.isEmpty ? "Listening..." : text)
        let estimatedTextWidth = CGFloat(displayText.count) * 14
        let badgeWidth: CGFloat = isContinuousMode ? 50 : 0
        let contentWidth = estimatedTextWidth + 44 + 12 + 40 + badgeWidth
        return min(max(contentWidth, 160), 560)
    }

    private func centeredFrame(width: CGFloat) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 80, width: width, height: 56)
        }

        let screenFrame = screen.visibleFrame
        let x = screenFrame.origin.x + (screenFrame.width - width) / 2
        let y = screenFrame.origin.y + 80

        return NSRect(x: x, y: y, width: width, height: 56)
    }
}
