import SwiftUI

enum Zone {
    case good, warn, bad, neutral

    var color: Color {
        switch self {
        case .good: Color(red: 0.19, green: 0.72, blue: 0.45)
        case .warn: Color(red: 0.97, green: 0.62, blue: 0.14)
        case .bad: Color(red: 0.91, green: 0.28, blue: 0.30)
        case .neutral: Color(red: 0.33, green: 0.52, blue: 0.98)
        }
    }

    var label: String {
        switch self {
        case .good: "OK"
        case .warn: "Borderline"
        case .bad: "Bad"
        case .neutral: ""
        }
    }
}

/// The scale of a metric: its full range and which parts of it are good, borderline or bad.
struct MetricSpec {
    let range: ClosedRange<Double>
    /// Zones in ascending order; each covers values up to and including `upTo`.
    let zones: [(upTo: Double, zone: Zone)]
    let format: (Double) -> String
    /// Compact label for the range ends under a gauge; defaults to `format`.
    var edgeFormat: ((Double) -> String)? = nil

    func edge(_ value: Double) -> String { (edgeFormat ?? format)(value) }

    func zone(for value: Double) -> Zone {
        zones.first { value <= $0.upTo }?.zone ?? zones.last?.zone ?? .neutral
    }

    func fraction(_ value: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    /// Zone bands clipped to the range, as (from, to, zone).
    var bands: [(from: Double, to: Double, zone: Zone)] {
        var lower = range.lowerBound
        var result: [(Double, Double, Zone)] = []
        for (upTo, zone) in zones {
            let upper = min(upTo, range.upperBound)
            if upper > lower { result.append((lower, upper, zone)) }
            lower = max(lower, upper)
        }
        if lower < range.upperBound, let last = zones.last { result.append((lower, range.upperBound, last.zone)) }
        return result
    }
}

// Quest 3 scales. Thresholds come from what we measured on this headset.
extension MetricSpec {
    static let totalRamMB = 7757.0
    static let totalSwapMB = 4608.0

    static func fps(target: Double) -> MetricSpec {
        MetricSpec(range: 0...target,
                   zones: [(target * 0.8, .bad), (target * 0.97, .warn), (target + 2, .good)],
                   format: { "\(Int($0.rounded()))" })
    }

    static func frameTime(budget: Double) -> MetricSpec {
        MetricSpec(range: 0...(budget * 2),
                   zones: [(budget, .good), (budget * 1.3, .warn), (budget * 2, .bad)],
                   format: { String(format: "%.1f ms", $0) },
                   edgeFormat: { String(format: "%.0f", $0) })
    }

    private static let integer: (Double) -> String = { "\(Int($0))" }

    static let gpuClock = MetricSpec(range: 285...690, zones: [(690, .neutral)],
                                     format: { "\(Int($0)) MHz" }, edgeFormat: integer)
    static let cpuClock = MetricSpec(range: 691...2361, zones: [(2361, .neutral)],
                                     format: { "\(Int($0)) MHz" }, edgeFormat: integer)
    static let gpuLoad = MetricSpec(range: 0...100, zones: [(85, .good), (97, .warn), (100, .bad)],
                                    format: { "\(Int($0))%" })
    static let gpuTemp = MetricSpec(range: 30...95, zones: [(80, .good), (88, .warn), (95, .bad)],
                                    format: { String(format: "%.1f °C", $0) },
                                    edgeFormat: { "\(Int($0))°" })
    static let memAvailable = MetricSpec(range: 0...totalRamMB,
                                         zones: [(500, .bad), (1500, .warn), (totalRamMB, .good)],
                                         format: { "\(Int($0)) MB" }, edgeFormat: integer)
    static let swapUsed = MetricSpec(range: 0...totalSwapMB,
                                     zones: [(1024, .good), (2560, .warn), (totalSwapMB, .bad)],
                                     format: { "\(Int($0)) MB" }, edgeFormat: integer)
}

/// A thin bar showing the zone layout of the scale with the current value filled in.
struct GaugeBar: View {
    let spec: MetricSpec
    let value: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let span = spec.range.upperBound - spec.range.lowerBound
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(Array(spec.bands.enumerated()), id: \.offset) { _, band in
                        Rectangle()
                            .fill(band.zone.color.opacity(0.18))
                            .frame(width: width * (band.to - band.from) / span)
                    }
                }
                .clipShape(Capsule())

                if let value {
                    let color = spec.zone(for: value).color
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.55), color],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(7, width * spec.fraction(value)))
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(color, lineWidth: 2))
                        .frame(width: 11, height: 11)
                        .offset(x: max(0, width * spec.fraction(value) - 5.5))
                }
            }
        }
        .frame(height: 11)
    }
}

struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}
