import SwiftUI

struct ControlPanel: View {
    @EnvironmentObject private var model: QuestModel
    @State private var tuning = Tuning()
    @State private var rebootFirst = false

    var body: some View {
        ScrollView {
            ControlPanelContent(tuning: $tuning, rebootFirst: $rebootFirst)
                .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: model.link) {
            guard case .connected = model.link else { return }
            if let t = await model.readTuning() { tuning = t }
            await model.loadGames()
        }
    }
}

struct ControlPanelContent: View {
    @EnvironmentObject private var model: QuestModel
    @Binding var tuning: Tuning
    @Binding var rebootFirst: Bool
    @State private var captureMode = QuestModel.CaptureMode.eye
    @Environment(\.openWindow) private var openWindow

    private var connected: Bool {
        if case .connected = model.link { return true }
        return false
    }

    private var pending: Bool { model.headsetTuning != tuning }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Stays usable while disconnected: it is how the app finds the headset over Wi-Fi.
            ConnectionCard()
                .disabled(model.busy)
            headsetControls
                .disabled(!connected || model.busy)
            statusLine
        }
    }

    private var headsetControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelCard(title: "Game", systemImage: "gamecontroller.fill") {
                HStack(spacing: 8) {
                    Picker("", selection: $model.game) {
                        ForEach(model.games.isEmpty ? [model.game] : model.games, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    Button("Restart") { Task { await model.restartGame() } }
                        .buttonStyle(PanelButtonStyle(kind: .secondary))
                }
            }

            PanelCard(title: "Live view", systemImage: "play.rectangle.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Streams what the headset shows into a window on this Mac, left eye, right eye or both. Works over Wi-Fi.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        openWindow(id: "live")
                    } label: {
                        Label("Open live view", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PanelButtonStyle(kind: .primary, large: true))
                }
            }

            PanelCard(title: "Screenshot", systemImage: "camera.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $captureMode) {
                        ForEach(QuestModel.CaptureMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(captureMode.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await model.capture(captureMode) }
                    } label: {
                        Label(model.capturing ? "Capturing…" : "Capture screenshot", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PanelButtonStyle(kind: .primary, large: true))
                    .disabled(model.capturing)
                    if let url = model.lastCapture {
                        CapturePreview(url: url)
                    }
                    Button("Open screenshots folder") {
                        try? FileManager.default.createDirectory(at: QuestModel.captureFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(QuestModel.captureFolder)
                    }
                    .buttonStyle(PanelButtonStyle(kind: .secondary))
                }
            }

            VideoCaptureCard()

            PanelCard(title: "Files", systemImage: "folder.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Browse the headset's storage. Download, upload, rename and delete files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        openWindow(id: "files")
                    } label: {
                        Label("Open file manager", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PanelButtonStyle(kind: .secondary, large: true))
                }
            }

            PanelCard(title: "Presets", systemImage: "square.stack.3d.up.fill") {
                HStack(spacing: 10) {
                    ForEach(Preset.allCases) { preset in
                        PresetCard(preset: preset,
                                   selected: tuning == preset.tuning,
                                   active: model.headsetTuning == preset.tuning) {
                            tuning = preset.tuning
                            Task { await model.apply(preset.tuning, label: preset.rawValue) }
                        }
                    }
                }
            }

            PanelCard(title: "Tuning", systemImage: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 18) {
                    tuningSelectors
                    tuningButtons
                }
            }

            PanelCard(title: "Free resources", systemImage: "memorychip.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Reboot headset first", isOn: $rebootFirst)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(model.link.isWifi)
                    if model.link.isWifi {
                        Text("Reboot needs the USB cable: Wi-Fi adb turns off when the headset restarts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        Task { await model.boost(reboot: rebootFirst && !model.link.isWifi, tuning: tuning) }
                    } label: {
                        Label("Free resources & launch game", systemImage: "bolt.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PanelButtonStyle(kind: .primary, large: true))
                    Text("Stops every other app and cached process, applies the tuning above, then starts the game. Core VR services are left alone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if model.busy || !model.status.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardBackground())
        }
    }

    @ViewBuilder
    private var tuningSelectors: some View {
        let applied = model.headsetTuning
        StepSelector(
            title: "GPU level",
            options: Tuning.gpuMHz.enumerated().map { StepOption(short: "\($0.element)", detail: "L\($0.offset) · \($0.element) MHz") },
            index: $tuning.gpuLevel,
            caption: tuning.gpuLevel == 7 ? "Undocumented top level. Watch GPU temperature." : "MHz per level. Higher is faster and hotter.",
            captionIsWarning: tuning.gpuLevel == 7,
            appliedIndex: applied?.gpuLevel)
        StepSelector(
            title: "CPU level",
            options: Tuning.cpuGHz.enumerated().map { StepOption(short: String(format: "%.1f", $0.element), detail: String(format: "L%d · %.2f GHz", $0.offset, $0.element)) },
            index: $tuning.cpuLevel,
            caption: "GHz on the app cores.",
            appliedIndex: applied?.cpuLevel)
        StepSelector(
            title: "Refresh rate",
            options: Tuning.refreshRates.map { StepOption(short: "\($0)", detail: "\($0) Hz") },
            index: $tuning.refreshIndex,
            caption: String(format: "Frame budget %.1f ms.", 1000 / Double(tuning.refreshRate)),
            appliedIndex: applied?.refreshIndex)
        StepSelector(
            title: "Foveation",
            options: Tuning.foveationNames.enumerated().map { StepOption(short: $0.offset == 0 ? "Off" : "\($0.offset)", detail: $0.element) },
            index: $tuning.foveation,
            tint: .accent,
            caption: "Higher is faster, with softer image edges.",
            appliedIndex: applied?.foveation)
        StepSelector(
            title: "Eye texture",
            options: Tuning.textureSizes.map { StepOption(short: "\($0.width)", detail: "\($0.width)×\($0.height)") },
            index: $tuning.textureIndex,
            caption: String(format: "%.1f MP per eye · %d%% of panel pixels. Restart the game to apply.",
                            tuning.texture.megapixels, tuning.texture.panelPercent),
            appliedIndex: applied?.textureIndex)
    }

    private var tuningButtons: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.apply(tuning) }
            } label: {
                Label(pending ? "Apply changes" : "Applied", systemImage: pending ? "arrow.up.circle.fill" : "checkmark.circle.fill")
            }
            .buttonStyle(PanelButtonStyle(kind: pending ? .primary : .secondary))
            .disabled(!pending)

            Button("Revert") { if let t = model.headsetTuning { tuning = t } }
                .buttonStyle(PanelButtonStyle(kind: .secondary))
                .disabled(!pending || model.headsetTuning == nil)

            Spacer()

            Button("Clear overrides") { Task { await model.resetTuning() } }
                .buttonStyle(PanelButtonStyle(kind: .destructive))
        }
    }
}

// MARK: - Video capture

/// Size, bitrate and frame rate of the headset's own Record video.
private struct VideoCaptureCard: View {
    @EnvironmentObject private var model: QuestModel
    @State private var capture = VideoCapture()

    private var applied: VideoCapture { model.headsetVideoCapture ?? VideoCapture() }
    private var pending: Bool { capture != applied }

    var body: some View {
        PanelCard(title: "Video capture", systemImage: "video.fill") {
            VStack(alignment: .leading, spacing: 18) {
                StepSelector(
                    title: "Size",
                    options: VideoCapture.sizes.map { StepOption(short: $0.short, detail: "\($0.width)×\($0.height)") },
                    index: $capture.sizeIndex,
                    tint: .accent,
                    caption: capture.sizeIndex == 1 ? "System default." : "Width × height of the recorded video. Larger sizes need a higher bitrate to stay sharp.",
                    appliedIndex: applied.sizeIndex)
                StepSelector(
                    title: "Quality",
                    options: VideoCapture.bitratesMbps.map { StepOption(short: "\($0)", detail: "\($0) Mbit/s") },
                    index: $capture.bitrateIndex,
                    tint: .accent,
                    caption: "Bitrate, Mbit/s. About \(capture.megabytesPerMinute) MB per minute of video.",
                    appliedIndex: applied.bitrateIndex)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Full frame rate", isOn: $capture.fullRate)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Text(capture.fullRate
                         ? "Records at the display refresh rate. Costs some GPU time while recording."
                         : "Records at half the display refresh rate (system default).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button {
                        Task { await model.applyVideoCapture(capture) }
                    } label: {
                        Label(pending ? "Apply changes" : "Applied", systemImage: pending ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                    }
                    .buttonStyle(PanelButtonStyle(kind: pending ? .primary : .secondary))
                    .disabled(!pending)

                    Spacer()

                    Button("Defaults") {
                        capture = VideoCapture()
                        Task { await model.resetVideoCapture() }
                    }
                    .buttonStyle(PanelButtonStyle(kind: .destructive))
                }
                Text("Used by Record video in the Quest menu, from the next recording on. The headset forgets these settings when it restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: model.link) {
            guard case .connected = model.link else { return }
            if let c = await model.readVideoCapture() { capture = c }
        }
    }
}

// MARK: - Building blocks

/// Thumbnail of the latest screenshot; click opens it in the default viewer.
private struct CapturePreview: View {
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .help("Open in Preview")
                HStack {
                    Text("\(url.lastPathComponent) · \(Int(image.representations.first?.pixelsWide ?? 0))×\(Int(image.representations.first?.pixelsHigh ?? 0))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }
}

/// How the app reaches the headset: USB, or Wi-Fi once adb on the headset listens on TCP.
private struct ConnectionCard: View {
    @EnvironmentObject private var model: QuestModel
    @State private var address = ""

    var body: some View {
        PanelCard(title: "Connection", systemImage: model.link.isWifi ? "wifi" : "cable.connector") {
            VStack(alignment: .leading, spacing: 10) {
                switch model.link {
                case .connected(let serial) where model.link.isWifi:
                    Text("Wi-Fi · \(serial)").font(.callout.weight(.semibold))
                    Text("The USB-C port is free, e.g. for a thermal camera. Wi-Fi adb stays on until the headset reboots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Disconnect & forget") { Task { await model.forgetWifi() } }
                        .buttonStyle(PanelButtonStyle(kind: .destructive))
                case .connected(let serial):
                    Text("USB · \(serial)").font(.callout.weight(.semibold))
                    Button {
                        Task { await model.enableWifi() }
                    } label: {
                        Label("Enable Wi-Fi", systemImage: "wifi").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PanelButtonStyle(kind: .primary, large: true))
                    Text("Switches adb on the headset to Wi-Fi and connects to it. Then the cable can be unplugged; the app reconnects by itself while the headset sleeps and wakes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    Text("Connect the USB cable, or enter the headset's address if Wi-Fi was enabled since its last reboot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        TextField("192.168.x.x", text: $address)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await model.connect(to: address) } }
                        Button("Connect") { Task { await model.connect(to: address) } }
                            .buttonStyle(PanelButtonStyle(kind: .secondary))
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if model.wifiAddress != nil {
                        Button("Forget saved address") { Task { await model.forgetWifi() } }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        .onAppear { if address.isEmpty { address = model.wifiAddress ?? "" } }
    }
}

struct PanelCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title.uppercased(), systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

private struct PresetCard: View {
    let preset: Preset
    let selected: Bool
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: preset.systemImage)
                        .font(.title3)
                        .foregroundStyle(selected ? Color.white : Zone.neutral.color)
                    Spacer()
                    if active {
                        Badge(text: "ON", color: selected ? .white : Zone.good.color)
                    }
                }
                Group {
                    Text(preset.rawValue).font(.subheadline.weight(.semibold))
                    Text(preset.subtitle).font(.caption2.monospacedDigit())
                    Text(preset.detail).font(.caption2.monospacedDigit())
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? AnyShapeStyle(LinearGradient(colors: [Zone.neutral.color, Zone.neutral.color.opacity(0.75)],
                                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                                   : AnyShapeStyle(Color.primary.opacity(0.05)))
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.clear : Color.primary.opacity(0.1)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

struct PanelButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }

    let kind: Kind
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((large ? Font.body : Font.callout).weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: !large, vertical: false)
            .padding(.horizontal, large ? 14 : 11)
            .padding(.vertical, large ? 9 : 6)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: .primary
        case .destructive: Zone.bad.color
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary:
            AnyShapeStyle(LinearGradient(colors: [Zone.neutral.color, Zone.neutral.color.opacity(0.8)],
                                         startPoint: .top, endPoint: .bottom))
        case .secondary: AnyShapeStyle(Color.primary.opacity(0.07))
        case .destructive: AnyShapeStyle(Zone.bad.color.opacity(0.1))
        }
    }
}
