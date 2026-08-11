import SwiftUI

/// Green under 70%, orange 70–89%, red at 90%+.
func usageTint(_ percent: Double) -> Color {
    if percent >= 90 { return .red }
    if percent >= 70 { return .orange }
    return .green
}

/// Circular usage ring, used by the widgets on both platforms.
struct UsageRing: View {
    let percent: Double
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, percent / 100))
                .stroke(usageTint(percent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Thin horizontal capacity bar, used by both the popover and the widget.
struct UsageBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(usageTint(percent))
                    .frame(width: max(4, geo.size.width * min(1, percent / 100)))
            }
        }
    }
}
