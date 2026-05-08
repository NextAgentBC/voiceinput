import Cocoa
import SwiftUI
import Observation

final class FloatingPanel: NSPanel {
    let model = FloatingPanelModel()

    private let baseSize: CGFloat = 60
    private let maxWidth: CGFloat = 360
    private let textHorizontalPadding: CGFloat = 24

    private var hostingView: NSHostingView<FloatingContentView>?
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    private var errorTimer: DispatchWorkItem?

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

        installHostingView()
        observeModelForWidth()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Setup

    private func installHostingView() {
        let hosting = NSHostingView(rootView: FloatingContentView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        guard let cv = contentView else { return }
        cv.addSubview(hosting)

        let w = hosting.widthAnchor.constraint(equalToConstant: baseSize)
        let h = hosting.heightAnchor.constraint(equalToConstant: baseSize)
        NSLayoutConstraint.activate([
            hosting.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            hosting.centerYAnchor.constraint(equalTo: cv.centerYAnchor),
            w, h,
        ])
        widthConstraint = w
        heightConstraint = h
        hostingView = hosting
    }

    /// Use `withObservationTracking` to watch only the text fields (not audioLevel)
    /// and recompute the panel width when they change.
    private func observeModelForWidth() {
        func observe() {
            withObservationTracking {
                _ = model.partialText
                _ = model.toastText
                _ = model.errorText
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    self?.recomputeWidth()
                    observe()
                }
            }
        }
        observe()
    }

    private func recomputeWidth() {
        let displayText = model.errorText ?? model.toastText ?? model.partialText
        let allowsWrap = (model.errorText == nil && model.toastText == nil && model.partialText != nil)
        let (targetWidth, targetHeight) = computeSize(for: displayText, allowsWrap: allowsWrap)
        widthConstraint?.constant = targetWidth
        heightConstraint?.constant = targetHeight
        if isVisible {
            setFrame(centeredFrame(width: targetWidth, height: targetHeight), display: true, animate: false)
        }
    }

    // MARK: - Public API

    func updateContent(audioLevel: Float, isRefining: Bool = false, partialText: String? = nil, toast: String? = nil, errorText: String? = nil) {
        let cleaned: String? = {
            guard let t = partialText else { return nil }
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        model.audioLevel = audioLevel
        model.isRefining = isRefining
        model.partialText = cleaned
        model.toastText = toast
        model.errorText = errorText
    }

    func showToast(_ text: String, duration: TimeInterval = 2.0) {
        model.toastText = text
        model.errorText = nil
        if !isVisible { showWithAnimation() }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.hideWithAnimation()
        }
    }

    func showError(_ text: String, duration: TimeInterval = 3.0) {
        errorTimer?.cancel()

        model.errorText = text
        if !isVisible { showWithAnimation() }

        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.model.errorText = nil
            self.hideWithAnimation()
        }
        errorTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    func showWithAnimation() {
        let displayText = model.errorText ?? model.toastText ?? model.partialText
        let allowsWrap = (model.errorText == nil && model.toastText == nil && model.partialText != nil)
        let (width, height) = computeSize(for: displayText, allowsWrap: allowsWrap)
        widthConstraint?.constant = width
        heightConstraint?.constant = height
        let frame = centeredFrame(width: width, height: height)
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
            self.model.partialText = nil
        })
    }

    // MARK: - Sizing

    /// Layout policy:
    ///   - Error / toast: single line, width grows up to maxWidth, height = baseSize.
    ///   - Partial transcript (allowsWrap): up to 3 lines, wraps at maxWidth.
    ///     Height grows in line-step increments.
    ///   - No text: baseSize × baseSize circle.
    private func computeSize(for text: String?, allowsWrap: Bool) -> (CGFloat, CGFloat) {
        guard let text = text, !text.isEmpty else { return (baseSize, baseSize) }
        let font = NSFont.preferredFont(forTextStyle: .body)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let singleLine = (text as NSString).size(withAttributes: attrs).width
        let textAreaPadding = textHorizontalPadding + 4   // capsule + .padding(.trailing, 12)
        let maxTextWidth = maxWidth - baseSize - textAreaPadding

        if !allowsWrap || singleLine <= maxTextWidth {
            // Fits on one line — use single-line geometry, baseSize height.
            let total = baseSize + singleLine + textHorizontalPadding
            return (min(maxWidth, max(baseSize, total)), baseSize)
        }

        // Multi-line: width pinned to maxWidth, height computed via NSAttributedString.
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        let lineHeight = font.ascender - font.descender + font.leading
        let maxLines = 3
        let cappedHeight = min(bounding.height, lineHeight * CGFloat(maxLines))
        let textHeight = ceil(cappedHeight) + 12   // .padding(.vertical, 6) on each side
        let totalHeight = max(baseSize, textHeight)
        return (maxWidth, totalHeight)
    }

    private func centeredFrame(width: CGFloat, height: CGFloat) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 100, width: width, height: height)
        }
        let sf = screen.visibleFrame
        return NSRect(x: sf.midX - width / 2, y: sf.minY + 100, width: width, height: height)
    }
}
