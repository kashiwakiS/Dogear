import SwiftUI

struct OperationFeedbackHUD: View {
    @ObservedObject var feedbackCenter: OperationFeedbackCenter
    @State private var isHovered = false

    var body: some View {
        Group {
            if let feedback = feedbackCenter.currentFeedback {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: feedback.kind.systemImage)
                        .foregroundStyle(feedback.kind.tint)
                        .font(.body.weight(.semibold))
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(feedback.message)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)

                        if feedbackCenter.detailLevel == .verbose {
                            verboseDetails(for: feedback)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        feedbackCenter.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Dismiss feedback")
                    .accessibilityLabel("Dismiss feedback")
                }
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.vertical, 10)
                .frame(width: 360, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
                .onHover { isHovered in
                    self.isHovered = isHovered
                    feedbackCenter.setPaused(isHovered)
                }
                .onChange(of: feedback.id) { _, _ in
                    if isHovered {
                        feedbackCenter.setPaused(true)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(feedback.message)
            }
        }
        .animation(.easeOut(duration: 0.18), value: feedbackCenter.currentFeedback?.id)
    }

    @ViewBuilder
    private func verboseDetails(for feedback: OperationFeedback) -> some View {
        let details = [feedback.action, feedback.trigger?.description].compactMap { $0 }

        if !details.isEmpty {
            Text(details.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private extension OperationFeedbackKind {
    var systemImage: String {
        switch self {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info:
            return .accentColor
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}
