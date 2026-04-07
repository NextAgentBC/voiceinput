import SwiftUI

struct FloatingContentView: View {
    let audioLevel: Float
    let isRefining: Bool

    private let size: CGFloat = 40

    var body: some View {
        ZStack {
            if !isRefining {
                Circle()
                    .fill(Color.green.opacity(0.15 + Double(audioLevel) * 0.25))
                    .scaleEffect(1.0 + CGFloat(audioLevel) * 0.6)
                    .blur(radius: 8)
                    .animation(.easeOut(duration: 0.12), value: audioLevel)
            }

            Circle()
                .fill(Color.black.opacity(0.75))
                .frame(width: size, height: size)

            if isRefining {
                ProgressView()
                    .controlSize(.mini)
                    .colorScheme(.dark)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.green)
                    .scaleEffect(1.0 + CGFloat(audioLevel) * 0.15)
                    .animation(.easeOut(duration: 0.1), value: audioLevel)
            }
        }
        .frame(width: size + 20, height: size + 20)
    }
}
