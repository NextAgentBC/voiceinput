import SwiftUI

struct WaveformView: View {
    let audioLevel: Float

    // Bar weights: center-high, sides-low
    private let barWeights: [Float] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private let barCount = 5
    private let barSpacing: CGFloat = 3
    private let barWidth: CGFloat = 4
    private let minBarHeight: CGFloat = 6
    private let maxBarHeight: CGFloat = 28

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let totalBarWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
                let startX = (size.width - totalBarWidth) / 2
                let centerY = size.height / 2

                for i in 0..<barCount {
                    let weight = barWeights[i]

                    // Add ±4% random jitter for organic feel
                    let jitter = Float.random(in: -0.04...0.04)
                    let level = max(0, min(1, audioLevel * weight + jitter))

                    let barHeight = minBarHeight + CGFloat(level) * (maxBarHeight - minBarHeight)
                    let x = startX + CGFloat(i) * (barWidth + barSpacing)
                    let y = centerY - barHeight / 2

                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)

                    context.fill(path, with: .color(.white.opacity(0.9)))
                }
            }
            .frame(width: 44, height: 32)
        }
    }
}
