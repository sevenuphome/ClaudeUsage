import SwiftUI

/// Green under 70%, orange 70–89%, red at 90%+.
func usageTint(_ percent: Double) -> Color {
    if percent >= 90 { return .red }
    if percent >= 70 { return .orange }
    return .green
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
