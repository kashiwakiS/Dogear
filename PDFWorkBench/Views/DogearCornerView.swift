import SwiftUI

struct DogearCornerView: View {
    let marker: DogearMarker?
    let isNightMode: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            ZStack(alignment: .topTrailing) {
                Color.clear
                if marker != nil {
                    Path { path in
                        path.move(to: CGPoint(x: 4, y: 4))
                        path.addLine(to: CGPoint(x: 30, y: 4))
                        path.addLine(to: CGPoint(x: 30, y: 30))
                        path.closeSubpath()
                    }
                    .fill(Color.yellow.opacity(isNightMode ? 0.86 : 0.78))

                    Path { path in
                        path.move(to: CGPoint(x: 4, y: 4))
                        path.addLine(to: CGPoint(x: 30, y: 30))
                    }
                    .stroke(Color.orange.opacity(0.7), lineWidth: 1)
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(marker == nil ? "Add Dog-ear" : "Remove Dog-ear")
        .accessibilityLabel(marker == nil ? "Add Dog-ear" : "Remove Dog-ear")
    }
}
