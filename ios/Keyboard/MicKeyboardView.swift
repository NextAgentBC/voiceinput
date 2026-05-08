import SwiftUI

@MainActor
final class KeyboardLiveStatusModel: ObservableObject {
    @Published var phase: AppGroupBridge.LiveStatus.Phase = .starting
    @Published var partialText: String = ""
    @Published var audioLevel: Float = 0
    @Published var errorMessage: String? = nil
    /// Set by the VC on each viewWillAppear; gates the mic button.
    @Published var hasFullAccess: Bool = true
}

struct MicKeyboardView: View {
    @ObservedObject var model: KeyboardLiveStatusModel
    let onTap: () -> Void
    let onSwitch: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            partialBar

            Spacer()

            micButton

            statusLabel
                .padding(.top, 8)

            Spacer()

            HStack {
                globeButton
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(height: 270)
        .background(Color(.systemBackground))
    }

    // MARK: - Subviews

    @ViewBuilder
    private var partialBar: some View {
        if model.phase == .recording && !model.partialText.isEmpty {
            Text(model.partialText)
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundColor(.white)
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.darkGray))
        }
    }

    private var micButton: some View {
        Button(action: {
            guard model.hasFullAccess else { return }
            onTap()
        }) {
            ZStack {
                Circle()
                    .fill(buttonColor)
                    .frame(width: 80, height: 80)
                    .overlay(
                        Circle()
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    .scaleEffect(model.phase == .recording ? 1.08 : 1.0)
                    .animation(
                        model.phase == .recording
                            ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                            : .easeInOut(duration: 0.15),
                        value: model.phase == .recording
                    )

                Image(systemName: "mic.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(micIconColor)
            }
        }
        .disabled(!model.hasFullAccess)
        .accessibilityLabel(accessibilityMicLabel)
    }

    private var statusLabel: some View {
        Group {
            if !model.hasFullAccess {
                Text("Enable Full Access in Settings → Keyboards → VoiceInput → Allow Full Access")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            } else {
                switch model.phase {
                case .starting where model.partialText.isEmpty:
                    Text("Tap to record")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                case .starting:
                    Text("Opening Voice Input\u{2026}")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                case .recording:
                    HStack(spacing: 4) {
                        Text(model.partialText.isEmpty ? "Listening" : String(model.partialText.prefix(40)))
                            .lineLimit(1)
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                        AnimatedDots()
                    }
                case .refining:
                    Text("Refining\u{2026}")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                case .done:
                    Text("\u{2713} Pasted")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.green)
                case .error:
                    Text(model.errorMessage ?? "Error")
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                case .cancelled:
                    Text("Cancelled")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var globeButton: some View {
        Button(action: onSwitch) {
            Image(systemName: "globe")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.primary)
                .frame(width: 36, height: 36)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel("Switch keyboard")
    }

    // MARK: - Helpers

    private var buttonColor: Color {
        if !model.hasFullAccess { return Color(.systemGray4) }
        switch model.phase {
        case .recording: return .red
        case .done:      return .green
        case .error:     return Color(.systemOrange)
        default:         return Color(.secondarySystemBackground)
        }
    }

    private var micIconColor: Color {
        if !model.hasFullAccess { return Color(.systemGray2) }
        switch model.phase {
        case .recording, .done, .error: return .white
        default: return .primary
        }
    }

    private var accessibilityMicLabel: String {
        model.hasFullAccess ? "Start voice input" : "Full access required"
    }
}

// MARK: - Animated dots

/// Three dots that cycle opacity to signal activity.
private struct AnimatedDots: View {
    @State private var step = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .frame(width: 5, height: 5)
                    .foregroundColor(.secondary)
                    .opacity(step == i ? 1.0 : 0.3)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 0.4).repeatForever(autoreverses: false)) {
                step = 0
            }
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                step = (step + 1) % 3
            }
        }
    }
}
