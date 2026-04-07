import Cocoa
import SwiftUI

final class FloatingPanel: NSPanel {
    private var hostingView: NSHostingView<FloatingContentView>?
    private let panelSize: CGFloat = 60

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 60, height: 60),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func updateContent(audioLevel: Float, isRefining: Bool = false) {
        let view = FloatingContentView(audioLevel: audioLevel, isRefining: isRefining)
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        hostingView?.removeFromSuperview()
        contentView?.addSubview(hosting)
        if let cv = contentView {
            NSLayoutConstraint.activate([
                hosting.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
                hosting.centerYAnchor.constraint(equalTo: cv.centerYAnchor),
                hosting.widthAnchor.constraint(equalToConstant: panelSize),
                hosting.heightAnchor.constraint(equalToConstant: panelSize),
            ])
        }
        self.hostingView = hosting
    }

    func showWithAnimation() {
        let frame = centeredFrame()
        setFrame(frame, display: true)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        })
    }

    func hideWithAnimation() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
            self.alphaValue = 1.0
        })
    }

    private func centeredFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 100, width: panelSize, height: panelSize)
        }
        let sf = screen.visibleFrame
        return NSRect(x: sf.midX - panelSize / 2, y: sf.minY + 100, width: panelSize, height: panelSize)
    }
}
