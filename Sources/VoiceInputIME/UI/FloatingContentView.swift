import SwiftUI

struct FloatingContentView: View {
    @Bindable var model: FloatingPanelModel

    private let size: CGFloat = 40

    private var hasPartial: Bool {
        guard let t = model.partialText else { return false }
        return !t.isEmpty
    }

    private var hasToast: Bool {
        guard let t = model.toastText else { return false }
        return !t.isEmpty
    }

    private var hasError: Bool {
        guard let t = model.errorText else { return false }
        return !t.isEmpty
    }

    var body: some View {
        if hasError {
            errorBody
        } else if hasToast {
            toastBody
        } else {
            normalBody
        }
    }

    private var errorBody: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.75))
                    .frame(width: size, height: size)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.red)
            }
            .frame(width: size + 20, height: size + 20)

            Text(model.errorText ?? "")
                .font(.body)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .foregroundColor(Color(NSColor.systemRed))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.trailing, 12)
        }
        .background(
            Capsule()
                .fill(Color.black.opacity(0.70))
        )
        .accessibilityLabel("Voice Input error")
        .accessibilityValue(model.errorText ?? "")
    }

    private var toastBody: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.75))
                    .frame(width: size, height: size)
                Image(systemName: "checkmark")
                    .font(.headline)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .foregroundColor(.green)
            }
            .frame(width: size + 20, height: size + 20)

            Text(model.toastText ?? "")
                .font(.body)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.trailing, 12)
        }
        .background(
            Capsule()
                .fill(Color.black.opacity(0.55))
        )
        .accessibilityLabel("Voice Input notification")
        .accessibilityValue(model.toastText ?? "")
    }

    private var normalBody: some View {
        HStack(spacing: 8) {
            ZStack {
                if !model.isRefining {
                    Circle()
                        .fill(Color.green.opacity(0.15 + Double(model.audioLevel) * 0.25))
                        .scaleEffect(1.0 + CGFloat(model.audioLevel) * 0.6)
                        .blur(radius: 8)
                        .animation(.easeOut(duration: 0.12), value: model.audioLevel)
                }

                Circle()
                    .fill(Color.black.opacity(0.75))
                    .frame(width: size, height: size)

                if model.isRefining {
                    ProgressView()
                        .controlSize(.mini)
                        .colorScheme(.dark)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.headline)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                        .foregroundColor(.green)
                        .scaleEffect(1.0 + CGFloat(model.audioLevel) * 0.15)
                        .animation(.easeOut(duration: 0.1), value: model.audioLevel)
                }
            }
            .frame(width: size + 20, height: size + 20)

            if hasPartial {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.partialText ?? "")
                        .font(.body)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                        .foregroundColor(.white)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("⌘C to copy")
                        .font(.caption2)
                        .foregroundColor(Color.white.opacity(0.55))
                }
                .padding(.trailing, 12)
                .padding(.vertical, 6)
            }
        }
        .background(
            Group {
                if hasPartial {
                    Capsule()
                        .fill(Color.black.opacity(0.55))
                }
            }
        )
        .accessibilityLabel(model.isRefining ? "Voice Input refining" : "Voice Input recording")
        .accessibilityValue(model.isRefining ? "" : "Audio level \(Int(model.audioLevel * 100)) percent")
    }
}
