import AVFoundation
import SwiftUI

/// Which part of the stereo frame to show. The headset display holds both eyes side by side.
enum EyeView: String, CaseIterable, Identifiable {
    case left = "Left"
    case both = "Both"
    case right = "Right"
    var id: String { rawValue }
}

/// The "Live View" window: the headset display or one of its cameras, streamed over adb.
struct LiveView: View {
    @EnvironmentObject private var model: QuestModel
    @StateObject private var stream = LiveStream.shared
    @AppStorage("liveSource") private var sourceKey = LiveStream.Source.display.key
    @AppStorage("liveEye") private var eye = EyeView.left
    @AppStorage("liveQuality") private var quality = LiveStream.Quality.medium
    @AppStorage("liveFps") private var fps = 60
    /// Camera capture size; empty means the camera's largest.
    @AppStorage("liveCameraSize") private var cameraSize = ""

    private var connected: Bool {
        if case .connected = model.link { return true }
        return false
    }

    private var source: LiveStream.Source { LiveStream.Source(key: sourceKey) }

    private var camera: LiveStream.Camera? {
        if case .camera(let id) = source { return stream.cameras.first { $0.id == id } }
        return nil
    }

    private var fpsChoices: [Int] {
        if case .camera = source { return camera?.fps ?? [30] }
        return LiveStream.displayFps
    }

    /// The stream the controls describe; the running stream restarts when it changes.
    private var desired: LiveStream.Config {
        let rate = fpsChoices.min { abs($0 - fps) < abs($1 - fps) } ?? fps
        switch source {
        case .display:
            return LiveStream.Config(source: source, quality: quality, cameraSize: nil, fps: rate)
        case .camera:
            let size = camera?.sizes.contains(cameraSize) == true ? cameraSize : nil
            return LiveStream.Config(source: source, quality: quality, cameraSize: size, fps: rate)
        }
    }

    var body: some View {
        ZStack {
            Color.black
            StereoVideo(layer: stream.layer, videoSize: stream.videoSize, eye: source == .display ? eye : .both)
                .opacity(stream.state == .live ? 1 : 0)
            overlay
        }
        .frame(minWidth: 560, minHeight: 360)
        .navigationTitle(source == .display ? "Live View" : (camera?.title ?? "Live View"))
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .task {
            await stream.loadCameras()
            if connected, !stream.isRunning { await stream.start(desired) }
        }
        .onChange(of: desired) { _, config in
            if stream.isRunning, stream.config != config { Task { await stream.start(config) } }
        }
        .onChange(of: model.link) { _, link in
            // The adb link the stream ran on is gone.
            guard case .connected = link else {
                if stream.isRunning { stream.stop() }
                return
            }
            Task { await stream.loadCameras() }
        }
        .onDisappear { stream.stop() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Source", selection: $sourceKey) {
                Label("Headset display", systemImage: "visionpro").tag(LiveStream.Source.display.key)
                if !stream.cameras.isEmpty { Divider() }
                ForEach(stream.cameras) { cam in
                    Label(cam.title, systemImage: "camera").tag(LiveStream.Source.camera(cam.id).key)
                }
            }
            .help("What to stream: the display as the lenses see it, or a headset camera")
        }
        ToolbarItem(placement: .principal) {
            if source == .display {
                Picker("Eye", selection: $eye) {
                    ForEach(EyeView.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Left eye, right eye or both")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let camera {
                Picker("Size", selection: $cameraSize) {
                    Text("Largest").tag("")
                    ForEach(camera.sizes.reversed(), id: \.self) { Text($0.replacingOccurrences(of: "x", with: "×")).tag($0) }
                }
                .help("Camera capture size")
            }
            Picker("Frame rate", selection: Binding(get: { desired.fps }, set: { fps = $0 })) {
                ForEach(fpsChoices, id: \.self) { Text("\($0) fps").tag($0) }
            }
            .help(source == .display ? "Highest frame rate of the stream" : "Camera frame rate")
            Picker("Quality", selection: $quality) {
                ForEach(LiveStream.Quality.allCases) { q in
                    Text(source == .display ? q.rawValue : "\(q.bitRate / 1_000_000) Mbit/s").tag(q)
                }
            }
            .help(source == .display ? "Stream resolution and bitrate. Lower is smoother over Wi-Fi." : "Stream bitrate")
            Button {
                if stream.isRunning { stream.stop() } else { Task { await stream.start(desired) } }
            } label: {
                Label(stream.isRunning ? "Stop" : "Start", systemImage: stream.isRunning ? "stop.fill" : "play.fill")
            }
            .disabled(!connected && !stream.isRunning)
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch stream.state {
        case .live:
            EmptyView()
        case .idle:
            message(connected ? "Stream stopped" : "Headset not connected",
                    systemImage: connected ? "play.rectangle" : "cable.connector.slash",
                    detail: connected ? "Press Start to see what the headset shows." : "Connect over USB or Wi-Fi in the main window.")
        case .starting(let step):
            VStack(spacing: 10) {
                ProgressView().controlSize(.large)
                Text(step).foregroundStyle(.white.opacity(0.8))
            }
        case .waiting:
            // The display only sends frames while it is on; cameras run while the headset is awake.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let slow = stream.connectedAt.map { context.date.timeIntervalSince($0) > 4 } ?? false
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text(slow ? "No picture yet. The headset sleeps while nobody wears it: put the headset on."
                              : "Waiting for the first frame…")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: 360)
                }
            }
        case .failed(let error):
            message("Stream failed", systemImage: "exclamationmark.triangle", detail: error)
        }
    }

    private func message(_ title: String, systemImage: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 34)).foregroundStyle(.white.opacity(0.6))
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .textSelection(.enabled)
                .frame(maxWidth: 380)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if case .connected(let serial) = model.link { parts.append(model.link.isWifi ? "Wi-Fi \(serial)" : "USB") }
        if stream.state == .live {
            if let size = stream.videoSize { parts.append("\(Int(size.width))×\(Int(size.height))") }
            parts.append("\(stream.fps) fps")
            parts.append(String(format: "%.1f Mbit/s", Double(stream.kbps) / 1000))
        } else if source == .display {
            parts.append(quality.summary)
        }
        return parts.joined(separator: " · ")
    }
}

/// Hosts the display layer and shows one half of the stereo frame (or all of it), letterboxed.
private struct StereoVideo: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let videoSize: CGSize?
    let eye: EyeView

    func makeNSView(context: Context) -> StereoVideoView {
        let view = StereoVideoView(videoLayer: layer)
        view.update(videoSize: videoSize, eye: eye)
        return view
    }

    func updateNSView(_ view: StereoVideoView, context: Context) {
        view.update(videoSize: videoSize, eye: eye)
    }
}

final class StereoVideoView: NSView {
    private let clip = CALayer()
    private let videoLayer: AVSampleBufferDisplayLayer
    private var videoSize = CGSize(width: 4128, height: 2208)
    private var eye = EyeView.left

    init(videoLayer: AVSampleBufferDisplayLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        clip.masksToBounds = true
        videoLayer.removeFromSuperlayer()
        clip.addSublayer(videoLayer)
        layer?.addSublayer(clip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(videoSize: CGSize?, eye: EyeView) {
        if let videoSize, videoSize.width > 0, videoSize.height > 0 { self.videoSize = videoSize }
        self.eye = eye
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The visible part: one eye is half the frame's width.
        let shown = CGSize(width: eye == .both ? videoSize.width : videoSize.width / 2, height: videoSize.height)
        let scale = min(bounds.width / shown.width, bounds.height / shown.height)
        let fitted = CGSize(width: shown.width * scale, height: shown.height * scale)
        clip.frame = CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
                            width: fitted.width, height: fitted.height)
        // The whole frame at the same scale, shifted so the chosen eye sits in the clip.
        let full = CGSize(width: videoSize.width * scale, height: fitted.height)
        videoLayer.frame = CGRect(x: eye == .right ? -fitted.width : 0, y: 0, width: full.width, height: full.height)
        CATransaction.commit()
    }
}
