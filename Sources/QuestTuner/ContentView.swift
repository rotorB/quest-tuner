import Charts
import SwiftUI

struct ContentView: View {
    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                Dashboard().padding(16)
            }
            .frame(minWidth: 380)
            Divider()
            ControlPanel()
                .frame(width: 380)
        }
        .frame(minWidth: 900, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Renders the dashboard and the control panel to a PNG; set QUESTTUNER_SNAPSHOT=/path/to.png to use it.
@MainActor
func writeDashboardSnapshot(to path: String, model: QuestModel) {
    let tuning = model.headsetTuning ?? Tuning()
    let view = HStack(alignment: .top, spacing: 0) {
        Dashboard().padding(16).frame(width: 760)
        ControlPanelContent(tuning: .constant(tuning), rebootFirst: .constant(false))
            .padding(14)
            .frame(width: 380)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .environmentObject(model)

    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

private struct Dashboard: View {
    var body: some View {
        // Ticks once a second so a link that went silent turns grey without waiting for data.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                StatusBar()
                ChartsGrid(now: context.date)
            }
        }
    }
}

// MARK: - Connection line

private struct StatusBar: View {
    @EnvironmentObject private var model: QuestModel

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(linkColor).frame(width: 9, height: 9)
            Text(linkText).font(.callout).foregroundStyle(.secondary)
            if model.isLive, model.latestVr == nil, case .connected = model.link {
                Text("· no VR app rendering").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let battery = model.battery {
                Label("\(battery)%", systemImage: batterySymbol(battery))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(battery < 20 ? Zone.bad.color : battery < 40 ? Zone.warn.color : .secondary)
            }
        }
        .lineLimit(1)
    }

    private var linkColor: Color {
        switch model.link {
        case .connected: model.isLive ? Zone.good.color : Color.secondary
        case .searching: Zone.warn.color
        case .noADB: Zone.bad.color
        }
    }

    private var linkText: String {
        switch model.link {
        case .connected(let serial) where !model.isLive: "No data from headset · \(serial) · reconnecting…"
        case .connected(let serial): model.link.isWifi ? "Wi-Fi · \(serial)" : "USB · \(serial)"
        case .searching: model.wifiAddress.map { "Waiting for headset over USB or Wi-Fi (\($0))…" }
            ?? "Waiting for headset over USB…"
        case .noADB: "adb not found (install with: brew install android-platform-tools)"
        }
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

// MARK: - Charts

private struct ChartsGrid: View {
    @EnvironmentObject private var model: QuestModel
    let now: Date

    var body: some View {
        let offline = !model.isLive
        let vr = model.vr
        let sys = model.sys
        let target = vr.last?.targetFps ?? Double(model.headsetTuning?.refreshRate ?? 90)
        let budget = 1000 / max(target, 1)
        let latestVr = model.latestVr
        let gpuLevel = latestVr?.gpuLevel ?? model.headsetTuning?.gpuLevel
        let cpuLevel = latestVr?.cpuLevel ?? model.headsetTuning?.cpuLevel

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 10)], spacing: 10) {
            MetricChart(title: "Frames per second", values: vr.map { ($0.time, $0.fps) },
                        now: now, offline: offline, spec: .fps(target: target), yDomain: 0...(target + 10),
                        detail: latestVr?.stale.map { "\($0) stale frames" })
            MetricChart(title: "Frame time", values: vr.compactMap { s in s.appMs.map { (s.time, $0) } },
                        now: now, offline: offline, spec: .frameTime(budget: budget), yDomain: 0...(budget * 2),
                        detail: String(format: "budget %.1f ms", budget))
            MetricChart(title: "GPU clock", values: sys.map { ($0.time, $0.gpuMHz) },
                        now: now, offline: offline, spec: .gpuClock, yDomain: 250...720,
                        detail: gpuLevel.map { "level \($0) of 7" })
            MetricChart(title: "GPU load", values: sys.map { ($0.time, $0.gpuBusy) },
                        now: now, offline: offline, spec: .gpuLoad, yDomain: 0...100)
            MetricChart(title: "GPU temperature", values: sys.map { ($0.time, $0.gpuTempC) },
                        now: now, offline: offline, spec: .gpuTemp, yDomain: 30...95)
            MetricChart(title: "CPU clock", values: vr.compactMap { s in s.cpuMHz.map { (s.time, $0) } },
                        now: now, offline: offline, spec: .cpuClock, yDomain: 600...2450,
                        detail: cpuLevel.map { "level \($0) of 6" })
            MetricChart(title: "RAM free", values: sys.map { ($0.time, $0.memAvailMB) },
                        now: now, offline: offline, spec: .memAvailable, yDomain: 0...MetricSpec.totalRamMB)
            MetricChart(title: "Swap used", values: sys.map { ($0.time, $0.swapUsedMB) },
                        now: now, offline: offline, spec: .swapUsed, yDomain: 0...MetricSpec.totalSwapMB)
        }
    }
}

private struct ChartPoint: Identifiable {
    let id: Int
    let x: Double
    let y: Double
}

/// A metric card: live chart with the current value in the middle, and the metric's
/// full range with its good/borderline/bad zones underneath.
private struct MetricChart: View {
    let title: String
    let values: [(Date, Double)]
    let now: Date
    /// No data from the headset: the card keeps its history but drops all color.
    let offline: Bool
    let spec: MetricSpec
    let yDomain: ClosedRange<Double>
    var detail: String? = nil

    var body: some View {
        let window = QuestModel.window
        // Samples are trimmed only when new ones arrive, so drop anything that has
        // scrolled past the left edge since then.
        let points = values.enumerated().compactMap { i, v -> ChartPoint? in
            let x = v.0.timeIntervalSince(now)
            guard x >= -window else { return nil }
            return ChartPoint(id: i, x: min(x, 0), y: min(max(v.1, yDomain.lowerBound), yDomain.upperBound))
        }
        // Offline, the last known value stays on screen (in grey) instead of a dash.
        let latest = offline
            ? (points.isEmpty ? nil : values.last?.1)
            : values.last.flatMap { now.timeIntervalSince($0.0) < 6 ? $0.1 : nil }
        let zone = offline ? nil : latest.map(spec.zone(for:))
        let color = zone?.color ?? Color.secondary
        let showsZones = !offline && spec.zones.contains { $0.zone != .neutral }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if offline {
                    Badge(text: "OFFLINE", color: .secondary)
                } else if let zone, zone != .neutral {
                    Badge(text: zone.label.uppercased(), color: zone.color)
                }
            }
            .frame(height: 18)

            Chart {
                if showsZones {
                    ForEach(Array(spec.bands.enumerated()), id: \.offset) { _, band in
                        RectangleMark(xStart: .value("Start", -window), xEnd: .value("End", 0),
                                      yStart: .value("Low", max(band.from, yDomain.lowerBound)),
                                      yEnd: .value("High", min(band.to, yDomain.upperBound)))
                            .foregroundStyle(band.zone.color.opacity(0.05))
                    }
                }
                ForEach(points) { p in
                    AreaMark(x: .value("Seconds", p.x), yStart: .value("Base", yDomain.lowerBound), yEnd: .value(title, p.y))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Seconds", p.x), y: .value(title, p.y))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
            }
            .chartXScale(domain: -window...0)
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: 30)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel {
                        if let seconds = value.as(Double.self) {
                            Text(seconds == 0 ? "now" : "\(Int(seconds))s")
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel()
                }
            }
            .chartPlotStyle { $0.clipped() }
            .chartOverlay { _ in
                HeadlineValue(text: latest.map(spec.format) ?? "—", color: color)
            }
            .frame(height: 150)
            .saturation(offline ? 0 : 1)
            .opacity(offline ? 0.55 : 1)

            VStack(spacing: 5) {
                GaugeBar(spec: spec, value: latest)
                HStack(spacing: 4) {
                    Text(spec.edge(spec.range.lowerBound))
                    Spacer(minLength: 4)
                    if let detail { Text(detail) }
                    Spacer(minLength: 4)
                    Text(spec.edge(spec.range.upperBound))
                }
                .lineLimit(1)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .saturation(offline ? 0 : 1)
            .opacity(offline ? 0.55 : 1)
        }
        .padding(12)
        .background(CardBackground())
        .animation(.easeInOut(duration: 0.3), value: offline)
    }
}

/// The current value, drawn large in the middle of a chart. A halo in the card color keeps it
/// legible where it crosses the line.
private struct HeadlineValue: View {
    let text: String
    let color: Color

    var body: some View {
        let halo = Color(nsColor: .controlBackgroundColor)
        Text(text)
            .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(color)
            .shadow(color: halo, radius: 2)
            .shadow(color: halo, radius: 3)
            .shadow(color: halo, radius: 6)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }
}
