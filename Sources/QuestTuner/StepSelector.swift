import SwiftUI

struct StepOption {
    /// Tick label under the track.
    let short: String
    /// Value shown in the header when selected.
    let detail: String
}

/// A discrete slider: every allowed value is a segment, so the whole range and the
/// current position are visible at a glance. Click or drag to choose.
struct StepSelector: View {
    enum Tint {
        /// Green → red: higher costs more power and heat.
        case heat
        /// Single accent color: a trade-off without a "hot" end.
        case accent
    }

    let title: String
    let options: [StepOption]
    @Binding var index: Int
    var tint: Tint = .heat
    var caption: String? = nil
    var captionIsWarning = false
    /// Index the headset currently runs, marked with a dot when it differs from the selection.
    var appliedIndex: Int? = nil

    private var last: Int { options.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            track
            ticks
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(captionIsWarning ? Zone.warn.color : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            Text(options[index].detail)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
            if index == last { Badge(text: "MAX", color: color(for: index)) }
            if index == 0 { Badge(text: "MIN", color: .secondary) }
        }
    }

    private var track: some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                ForEach(0..<options.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(i <= index ? AnyShapeStyle(color(for: i)) : AnyShapeStyle(Color.primary.opacity(0.09)))
                        .frame(height: i == index ? 16 : 10)
                        .overlay(alignment: .top) {
                            if let appliedIndex, appliedIndex == i, appliedIndex != index {
                                Circle().fill(Color.primary.opacity(0.55)).frame(width: 4, height: 4).offset(y: -7)
                            }
                        }
                }
            }
            .frame(height: 16)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let step = geo.size.width / CGFloat(options.count)
                let i = Int(drag.location.x / step)
                index = min(max(i, 0), last)
            })
        }
        .frame(height: 16)
    }

    @ViewBuilder
    private var ticks: some View {
        if options.count <= 8 {
            HStack(spacing: 3) {
                ForEach(0..<options.count, id: \.self) { i in
                    Text(options[i].short)
                        .font(.caption2.monospacedDigit().weight(i == index ? .semibold : .regular))
                        .foregroundStyle(i == index ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        } else {
            HStack {
                Text(options[0].short)
                Spacer()
                Text("\(options.count) steps")
                Spacer()
                Text(options[last].short)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func color(for i: Int) -> Color {
        let t = last > 0 ? Double(i) / Double(last) : 1
        switch tint {
        case .heat:
            // Hue from green (0.36) through amber to red (0.0).
            return Color(hue: 0.36 * (1 - t), saturation: 0.72, brightness: 0.86)
        case .accent:
            return Zone.neutral.color.opacity(0.45 + 0.55 * t)
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}
