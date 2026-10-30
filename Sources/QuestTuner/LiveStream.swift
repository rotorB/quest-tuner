import AppKit
import AVFoundation
import CoreMedia
import Foundation
import Network

/// Streams the headset display or one of its cameras into this app. Runs the scrcpy server (from the
/// Homebrew scrcpy install) on the headset and decodes its H.264 stream into an AVSampleBufferDisplayLayer.
/// Works over whichever adb link is active, so over Wi-Fi as well as USB.
@MainActor
final class LiveStream: ObservableObject {
    static let shared = LiveStream()

    enum State: Equatable {
        case idle
        case starting(String)
        /// Connected, waiting for the first picture.
        case waiting
        case live
        case failed(String)
    }

    enum Quality: String, CaseIterable, Identifiable {
        case low = "Low"
        case medium = "Medium"
        case high = "High"

        var id: String { rawValue }
        /// Longest side of the stereo frame (the panel is 4128×2208, both eyes side by side).
        var maxSize: Int {
            switch self {
            case .low: 1920
            case .medium: 2752
            case .high: 4128
            }
        }
        var bitRate: Int {
            switch self {
            case .low: 4_000_000
            case .medium: 8_000_000
            case .high: 16_000_000
            }
        }
        var summary: String { "\(maxSize / 2) px per eye · \(bitRate / 1_000_000) Mbit/s" }
    }

    /// What to stream: the headset display (both eyes, as the panels show them) or a camera.
    enum Source: Hashable {
        case display
        case camera(Int)

        /// For @AppStorage: "display" or "camera:50".
        var key: String {
            switch self {
            case .display: "display"
            case .camera(let id): "camera:\(id)"
            }
        }

        init(key: String) {
            if key.hasPrefix("camera:"), let id = Int(key.dropFirst(7)) { self = .camera(id) } else { self = .display }
        }
    }

    /// A camera the headset exposes through Camera2, as the scrcpy server lists it.
    struct Camera: Identifiable, Hashable {
        let id: Int
        let facing: String
        /// "1280x1280" and so on, largest last.
        let sizes: [String]
        let fps: [Int]

        var title: String {
            // Meta's Passthrough Camera API: 50 is the left front camera, 51 the right one.
            switch id {
            case 50: "Left passthrough camera"
            case 51: "Right passthrough camera"
            default: "Camera \(id) (\(facing))"
            }
        }
    }

    struct Config: Equatable {
        var source: Source
        var quality: Quality
        /// Camera only: capture size, nil for the camera's largest.
        var cameraSize: String?
        var fps: Int
    }

    static let displayFps = [30, 60, 90]

    @Published private(set) var state: State = .idle
    @Published private(set) var videoSize: CGSize?
    @Published private(set) var fps = 0
    @Published private(set) var kbps = 0
    /// When the stream connected; the view shows a hint if no picture follows.
    @Published private(set) var connectedAt: Date?
    /// Cameras of the connected headset; empty until `loadCameras` ran.
    @Published private(set) var cameras: [Camera] = []
    /// What the running stream shows.
    @Published private(set) var config: Config?

    let layer = AVSampleBufferDisplayLayer()

    private var server: LineStream?
    private var serverLog: [String] = []
    private var receiver: StreamReceiver?
    private var forward: (serial: String, port: Int)?
    private var generation = 0

    private static let remoteJar = "/data/local/tmp/scrcpy-server.jar"

    var isRunning: Bool {
        switch state {
        case .idle, .failed: false
        default: true
        }
    }

    init() {
        layer.videoGravity = .resize
        layer.backgroundColor = NSColor.black.cgColor
    }

    /// Asks the scrcpy server for the headset's cameras, their sizes and frame rates.
    func loadCameras() async {
        guard case .connected(let serial) = QuestModel.shared.link,
              let install = await Self.findScrcpy(), install.major >= 5,
              await ADB.run(["-s", serial, "push", install.server, Self.remoteJar], timeout: 30).status == 0 else { return }
        let command = "CLASSPATH=\(Self.remoteJar) app_process / com.genymobile.scrcpy.Server \(install.version) list_camera_sizes=true 2>&1"
        let output = await ADB.run(["-s", serial, "shell", command], timeout: 20).output
        cameras = Self.parseCameras(output)
    }

    /// Lines such as `--camera-id=50    (back, 1280x1280, fps={15, 30, 60}, zoom-range=[1, 1])`,
    /// each followed by `- 1280x720` size lines.
    private static func parseCameras(_ output: String) -> [Camera] {
        var cameras: [Camera] = []
        var current: (id: Int, facing: String, fps: [Int], sizes: [String])?
        func flush() {
            if let c = current { cameras.append(Camera(id: c.id, facing: c.facing, sizes: c.sizes, fps: c.fps)) }
            current = nil
        }
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("--camera-id=") {
                flush()
                let id = Int(line.dropFirst(12).prefix { $0.isNumber }) ?? -1
                let inside = line.split(separator: "(", maxSplits: 1).last.map(String.init) ?? ""
                let facing = inside.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "unknown"
                var fps: [Int] = []
                if let open = line.range(of: "fps={"), let close = line[open.upperBound...].firstIndex(of: "}") {
                    fps = line[open.upperBound..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                }
                current = (id, facing, fps, [])
            } else if line.hasPrefix("- "), current != nil {
                current?.sizes.append(String(line.dropFirst(2)))
            }
        }
        flush()
        return cameras.filter { $0.id >= 0 }
    }

    func start(_ config: Config) async {
        stop()
        guard case .connected(let serial) = QuestModel.shared.link else {
            state = .failed("Headset not connected.")
            return
        }
        generation += 1
        let gen = generation

        guard let install = await Self.findScrcpy() else {
            state = .failed("scrcpy is not installed. Install it with: brew install scrcpy")
            return
        }
        guard install.major >= 5 else {
            state = .failed("scrcpy \(install.version) is too old for this viewer. Update it with: brew upgrade scrcpy")
            return
        }

        state = .starting("Copying the stream server to the headset…")
        let push = await ADB.run(["-s", serial, "push", install.server, Self.remoteJar], timeout: 30)
        guard gen == generation else { return }
        guard push.status == 0 else {
            state = .failed("Could not copy the stream server: \(push.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }

        // The server listens on a local abstract socket named after scid; adb forwards a Mac port to it.
        let scid = String(format: "%08x", Int.random(in: 0..<0x7FFF_FFFF))
        let forwardOutput = await ADB.run(["-s", serial, "forward", "tcp:0", "localabstract:scrcpy_\(scid)"], timeout: 10).output
        guard gen == generation else { return }
        guard let port = Int(forwardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            state = .failed("adb forward failed: \(forwardOutput)")
            return
        }
        forward = (serial, port)

        state = .starting("Starting the stream…")
        serverLog = []
        self.config = config
        var options = [
            "scid=\(scid)", "log_level=info", "audio=false", "control=false", "tunnel_forward=true",
            "send_device_meta=false", "video_codec=h264", "video_bit_rate=\(config.quality.bitRate)", "cleanup=true",
        ]
        switch config.source {
        case .display:
            options += ["video_source=display", "max_size=\(config.quality.maxSize)", "max_fps=\(config.fps)"]
        case .camera(let id):
            options += ["video_source=camera", "camera_id=\(id)", "camera_fps=\(config.fps)"]
            if let size = config.cameraSize { options.append("camera_size=\(size)") }
        }
        let optionList = options.joined(separator: " ")
        let command = "CLASSPATH=\(Self.remoteJar) app_process / com.genymobile.scrcpy.Server \(install.version) \(optionList) 2>&1"
        server = LineStream(args: ["-s", serial, "shell", command], onLine: { [weak self] line in
            guard let self, gen == self.generation else { return }
            self.serverLog = Array((self.serverLog + [line]).suffix(20))
        }, onExit: { [weak self] in
            guard let self, gen == self.generation else { return }
            self.fail(self.serverError ?? "The stream server stopped.")
        })

        let receiver = StreamReceiver(port: UInt16(port), layer: layer)
        receiver.onConnected = { [weak self] in
            guard let self, gen == self.generation else { return }
            self.state = .waiting
            self.connectedAt = Date()
        }
        receiver.onSize = { [weak self] size in
            guard let self, gen == self.generation else { return }
            self.videoSize = size
        }
        receiver.onFrame = { [weak self] in
            guard let self, gen == self.generation, self.state != .live else { return }
            self.state = .live
        }
        receiver.onStats = { [weak self] fps, kbps in
            guard let self, gen == self.generation else { return }
            self.fps = fps
            self.kbps = kbps
        }
        receiver.onEnd = { [weak self] message in
            guard let self, gen == self.generation else { return }
            self.fail(self.serverError ?? message)
        }
        self.receiver = receiver
        receiver.start()
    }

    func stop() {
        generation += 1
        receiver?.stop()
        receiver = nil
        server?.stop()
        server = nil
        if let forward {
            Task { await ADB.run(["-s", forward.serial, "forward", "--remove", "tcp:\(forward.port)"], timeout: 5) }
        }
        forward = nil
        layer.flushAndRemoveImage()
        fps = 0
        kbps = 0
        connectedAt = nil
        videoSize = nil
        config = nil
        state = .idle
    }

    private func fail(_ message: String) {
        stop()
        state = .failed(message)
    }

    /// The server's own error line, if it printed one.
    private var serverError: String? {
        serverLog.last { $0.contains("ERROR") || $0.contains("Exception") }
            .map { $0.replacingOccurrences(of: "[server] ", with: "") }
    }

    private struct ScrcpyInstall {
        let server: String
        let version: String
        var major: Int { Int(version.split(separator: ".").first ?? "") ?? 0 }
    }

    /// The server jar has to match the scrcpy version exactly, so both come from the same install.
    private static func findScrcpy() async -> ScrcpyInstall? {
        let prefixes = ["/opt/homebrew", "/usr/local"]
        for prefix in prefixes {
            let binary = prefix + "/bin/scrcpy"
            let server = prefix + "/share/scrcpy/scrcpy-server"
            guard FileManager.default.isExecutableFile(atPath: binary),
                  FileManager.default.fileExists(atPath: server) else { continue }
            let output = await runTool(binary, ["--version"])
            // First line: "scrcpy 5.0.1 <https://github.com/Genymobile/scrcpy>"
            let words = output.split(separator: "\n").first?.split(separator: " ") ?? []
            if words.count >= 2, words[0] == "scrcpy" {
                return ScrcpyInstall(server: server, version: String(words[1]))
            }
        }
        return nil
    }

    private static func runTool(_ path: String, _ args: [String]) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                guard (try? process.run()) != nil else {
                    cont.resume(returning: "")
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}

/// Reads the scrcpy video socket (protocol of scrcpy 5) and enqueues decoded-ready samples.
/// Everything here runs on its own serial queue; callbacks arrive on the main actor.
private final class StreamReceiver: @unchecked Sendable {
    var onConnected: (@MainActor () -> Void)?
    var onSize: (@MainActor (CGSize) -> Void)?
    var onFrame: (@MainActor () -> Void)?
    var onStats: (@MainActor (Int, Int) -> Void)?
    var onEnd: (@MainActor (String) -> Void)?

    private let port: UInt16
    private let layer: AVSampleBufferDisplayLayer
    private let queue = DispatchQueue(label: "QuestTuner.live-stream")
    private var connection: NWConnection?
    private var stopped = false
    private var attempts = 0
    private var format: CMVideoFormatDescription?
    private var frames = 0
    private var bytes = 0
    private var statsStart = Date()

    init(port: UInt16, layer: AVSampleBufferDisplayLayer) {
        self.port = port
        self.layer = layer
    }

    func start() {
        queue.async { self.connect() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.connection?.cancel()
            self.connection = nil
        }
    }

    private func main(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    // MARK: Connection

    /// adb accepts the local connection even before the server listens and then drops it, so
    /// keep reconnecting until the server's first byte (the "dummy byte") arrives.
    private func connect() {
        guard !stopped else { return }
        attempts += 1
        guard attempts <= 150 else {
            end("The headset did not start the stream.")
            return
        }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.connection = connection
        connection.start(queue: queue)
        read(1) { [weak self] data in
            guard let self else { return }
            guard data != nil else {
                connection.cancel()
                self.queue.asyncAfter(deadline: .now() + 0.1) { self.connect() }
                return
            }
            let callback = self.onConnected
            self.main { callback?() }
            self.readCodec()
        }
    }

    /// Reads exactly `count` bytes; nil when the connection closed or failed first.
    private func read(_ count: Int, _ completion: @escaping (Data?) -> Void) {
        guard let connection, !stopped else { return }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            completion(data?.count == count && error == nil ? data : nil)
        }
    }

    private func end(_ message: String) {
        guard !stopped else { return }
        stopped = true
        connection?.cancel()
        let callback = onEnd
        main { callback?(message) }
    }

    // MARK: Protocol

    private func readCodec() {
        read(4) { [weak self] data in
            guard let self else { return }
            guard let data else { return self.end("The stream closed before it started.") }
            guard data == Data("h264".utf8) else { return self.end("Unexpected video codec from the headset.") }
            self.readHeader()
        }
    }

    /// 12 bytes: a session packet (MSB set: width, height) or a media packet header.
    private func readHeader() {
        read(12) { [weak self] header in
            guard let self else { return }
            guard let header else { return self.end("The stream ended.") }
            let b = [UInt8](header)
            if b[0] & 0x80 != 0 {
                let width = Self.u32(b, 4), height = Self.u32(b, 8)
                let callback = self.onSize
                self.main { callback?(CGSize(width: Int(width), height: Int(height))) }
                self.readHeader()
                return
            }
            let isConfig = b[0] & 0x40 != 0
            let isKey = b[0] & 0x20 != 0
            let size = Int(Self.u32(b, 8))
            guard size > 0, size < 32 << 20 else { return self.end("Corrupt stream data.") }
            self.read(size) { [weak self] payload in
                guard let self else { return }
                guard let payload else { return self.end("The stream ended.") }
                self.handle(payload, config: isConfig, key: isKey)
                self.readHeader()
            }
        }
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    // MARK: H.264

    private func handle(_ packet: Data, config: Bool, key: Bool) {
        let nals = Self.nalUnits(in: packet)
        if config {
            // SPS and PPS: rebuild the format, which also covers a size change.
            let sps = nals.first { $0.first.map { $0 & 0x1F == 7 } ?? false }
            let pps = nals.first { $0.first.map { $0 & 0x1F == 8 } ?? false }
            if let sps, let pps { format = Self.makeFormat(sps: sps, pps: pps) }
            return
        }
        guard let format else { return }
        // AVCC sample: each slice prefixed with its 4-byte big-endian length.
        var avcc = Data()
        for nal in nals {
            guard let type = nal.first.map({ $0 & 0x1F }), type == 1 || type == 5 else { continue }
            var length = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4))
            avcc.append(nal)
        }
        guard !avcc.isEmpty, let sample = Self.makeSample(avcc, format: format, key: key) else { return }

        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)

        frames += 1
        bytes += packet.count
        if frames == 1 {
            let callback = onFrame
            main { callback?() }
        }
        let elapsed = Date().timeIntervalSince(statsStart)
        if elapsed >= 1 {
            let fps = Int((Double(frames) / elapsed).rounded())
            let kbps = Int(Double(bytes) * 8 / elapsed / 1000)
            frames = 0
            bytes = 0
            statsStart = Date()
            let callback = onStats
            main { callback?(fps, kbps) }
        }
    }

    /// Splits Annex B data at 00 00 01 / 00 00 00 01 start codes.
    private static func nalUnits(in data: Data) -> [Data] {
        let b = [UInt8](data)
        var starts: [(code: Int, payload: Int)] = []
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                starts.append((i > 0 && b[i - 1] == 0 ? i - 1 : i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        return starts.indices.compactMap { k in
            let from = starts[k].payload
            let to = k + 1 < starts.count ? starts[k + 1].code : b.count
            return from < to ? Data(b[from..<to]) : nil
        }
    }

    private static func makeFormat(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    private static func makeSample(_ avcc: Data, format: CMVideoFormatDescription, key: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }

        // No clock: show every frame as soon as it is decoded.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !key {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}
