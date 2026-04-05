import SwiftUI

struct FloatingContentView: View {
    let text: String
    let audioLevel: Float
    let isRefining: Bool
    let isContinuousMode: Bool

    private let minWidth: CGFloat = 160
    private let maxWidth: CGFloat = 560
    private let capsuleHeight: CGFloat = 56

    var body: some View {
        HStack(spacing: 12) {
            if isRefining {
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
                    .frame(width: 44, height: 32)
            } else {
                WaveformView(audioLevel: audioLevel)
            }

            Text(displayText)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: textWidth, alignment: .leading)

            if isContinuousMode && !isRefining {
                // Small "AUTO" badge to indicate continuous mode
                Text("AUTO")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(.white.opacity(0.15))
                    )
            }
        }
        .padding(.horizontal, 20)
        .frame(height: capsuleHeight)
        .frame(minWidth: minWidth, maxWidth: computedWidth)
        .background(
            RoundedRectangle(cornerRadius: capsuleHeight / 2)
                .fill(.clear)
        )
        .animation(.easeInOut(duration: 0.25), value: text)
    }

    private var displayText: String {
        if isRefining { return "Refining..." }
        return text.isEmpty ? "Listening..." : text
    }

    private var textWidth: CGFloat {
        let estimatedWidth = CGFloat(displayText.count) * 14
        return min(max(estimatedWidth, 100), maxWidth - 100)
    }

    private var computedWidth: CGFloat {
        let badgeWidth: CGFloat = isContinuousMode ? 50 : 0
        let contentWidth = textWidth + 44 + 12 + 40 + badgeWidth
        return min(max(contentWidth, minWidth), maxWidth)
    }
}
