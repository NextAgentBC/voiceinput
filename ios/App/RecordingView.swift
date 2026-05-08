import SwiftUI

// MARK: - ViewModel

@MainActor
final class RecordingViewModel: ObservableObject {
    @Published var phase: AppGroupBridge.LiveStatus.Phase = .starting
    @Published var partialText: String = ""
    @Published var audioLevel: Float = 0
    @Published var errorMessage: String?

    private var statusToken: NSObjectProtocol?

    init() {
        statusToken = AppGroupBridge.observe(AppGroupBridge.didUpdateStatusNotification) { [weak self] in
            self?.handleStatusUpdate()
        }
    }

    private func handleStatusUpdate() {
        guard let status = AppGroupBridge.readStatus() else { return }
        phase = status.phase
        if let text = status.partialText { partialText = text }
        audioLevel = status.audioLevel
        if let msg = status.errorMessage { errorMessage = msg }
    }
}

// MARK: - View

struct RecordingView: View {
    let requestID: UUID
    let language: String

    @StateObject private var vm = RecordingViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Live partial transcript
                partialTranscriptSection
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)

                // Audio-level circle
                audioLevelCircle
                    .padding(.bottom, 40)

                // Controls
                controlRow
                    .padding(.horizontal, 40)
                    .padding(.bottom, 20)

                // Hint
                Text("Switch back to your app — text will paste automatically.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 48)
            }
        }
        .task {
            await RecordingEngine.shared.start(requestID: requestID, language: language)
        }
        .onChange(of: vm.phase) { _, newPhase in
            if newPhase == .done || newPhase == .error || newPhase == .cancelled {
                scheduleDismiss()
            }
        }
    }

    // MARK: - Subviews

    private var partialTranscriptSection: some View {
        Group {
            if vm.partialText.isEmpty && vm.phase == .starting {
                Text("Listening…")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if vm.phase == .error {
                Text(vm.errorMessage ?? "An error occurred.")
                    .font(.body)
                    .foregroundStyle(.red.opacity(0.85))
                    .frame(maxWidth: .infinity * 0.8, alignment: .leading)
                    .multilineTextAlignment(.leading)
            } else {
                Text(vm.partialText.isEmpty ? "Listening…" : vm.partialText)
                    .font(.body)
                    .foregroundStyle(vm.partialText.isEmpty ? .white.opacity(0.5) : .white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: .leading)
    }

    private var audioLevelCircle: some View {
        ZStack {
            // Animated glow
            Circle()
                .fill(Color.green.opacity(0.18 + Double(vm.audioLevel) * 0.28))
                .scaleEffect(1.0 + CGFloat(vm.audioLevel) * 0.55)
                .blur(radius: 10)
                .animation(.easeOut(duration: 0.12), value: vm.audioLevel)
                .frame(width: 80, height: 80)

            // Base circle
            Circle()
                .fill(Color.black.opacity(0.8))
                .frame(width: 80, height: 80)
                .overlay(
                    Circle().stroke(Color.green.opacity(0.6), lineWidth: 2)
                )

            // Icon
            Group {
                if vm.phase == .starting {
                    ProgressView()
                        .tint(.green)
                } else if vm.phase == .done {
                    Image(systemName: "checkmark")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.green)
                } else if vm.phase == .error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                } else if vm.phase == .cancelled {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                        .scaleEffect(1.0 + CGFloat(vm.audioLevel) * 0.2)
                        .animation(.easeOut(duration: 0.1), value: vm.audioLevel)
                }
            }
        }
    }

    private var controlRow: some View {
        HStack(spacing: 48) {
            // Cancel
            Button {
                RecordingEngine.shared.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.red.opacity(0.85))
            }
            .disabled(vm.phase == .done || vm.phase == .error || vm.phase == .cancelled)
            .accessibilityLabel("Cancel")

            // Stop
            Button {
                RecordingEngine.shared.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
            }
            .disabled(vm.phase == .done || vm.phase == .error || vm.phase == .cancelled)
            .accessibilityLabel("Stop recording")
        }
    }

    // MARK: - Dismiss

    private func scheduleDismiss() {
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        }
    }
}
