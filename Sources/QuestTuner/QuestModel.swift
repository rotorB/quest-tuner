import Foundation

protocol Timed {
    var time: Date { get }
}

/// One VrApi stats line; the compositor logs one per second while a VR app runs.
struct VrSample: Identifiable, Timed {
    let id = UUID()
    let time: Date
    var fps: Double = 0
    var targetFps: Double = 0
    var appMs: Double?
    var stale: Int?
    var cpuLevel: Int?
    var gpuLevel: Int?
    var cpuMHz: Double?
    var gpuMHz: Double?
    var gpuUtil: Double?
    var cpuUtil: Double?
    var freeMB: Double?
}

/// One reading from the on-headset sampler loop.
struct SysSample: Identifiable, Timed {
    let id = UUID()
    let time: Date
    var gpuMHz: Double
    var gpuBusy: Double
    var gpuTempC: Double
    var memAvailMB: Double
    var swapUsedMB: Double
}

@MainActor
final class QuestModel: ObservableObject {
    static let shared = QuestModel()
    static let window: TimeInterval = 180
    static let defaultGame = "com.alf.alyxquest"

    enum Link: Equatable {
        case noADB
        case searching
        case connected(String)

        /// adb names network devices host:port and USB devices by their serial number.
        var isWifi: Bool {
            if case .connected(let serial) = self { return serial.contains(":") }
            return false
        }
    }

    static let wifiPort = 5555
    private static let wifiAddressKey = "wifiAddress"

    /// Last headset address used over Wi-Fi (host:port); reconnected automatically.
    @Published private(set) var wifiAddress = UserDefaults.standard.string(forKey: QuestModel.wifiAddressKey)
    private var lastConnectAttempt = Date.distantPast

    @Published private(set) var link: Link = .searching
    @Published private(set) var vr: [VrSample] = []
    @Published private(set) var sys: [SysSample] = []
    @Published private(set) var battery: Int?
    @Published private(set) var games: [String] = []
    @Published var game = QuestModel.defaultGame
    enum CaptureMode: String, CaseIterable, Identifiable {
        case eye = "Eye view"
        case display = "Full display"

        var id: String { rawValue }

        var summary: String {
            switch self {
            case .eye: "1440×1440 JPG of one eye, as you see it. Meta also keeps a copy in the headset gallery, which may sync to your Meta account."
            case .display: "4128×2208 PNG, both eyes at panel resolution, with lens distortion. Stays on this Mac. Takes about 6 s."
            }
        }
    }

    static let captureFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Quest Tuner", isDirectory: true)

    @Published private(set) var lastCapture: URL?
    @Published private(set) var capturing = false

    /// What the headset currently runs; nil when overrides are cleared or not read yet.
    @Published private(set) var headsetTuning: Tuning?
    @Published private(set) var headsetVideoCapture: VideoCapture?
    @Published private(set) var busy = false
    @Published private(set) var status = ""

    private(set) var serial: String?
    private var logStream: LineStream?
    private var pollStream: LineStream?
    private var watchdog: Task<Void, Never>?

    var latestVr: VrSample? {
        guard let last = vr.last, Date().timeIntervalSince(last.time) < 4 else { return nil }
        return last
    }

    var latestSys: SysSample? {
        guard let last = sys.last, Date().timeIntervalSince(last.time) < 6 else { return nil }
        return last
    }

    /// True while the headset answers. The sampler reports every 2 s whether or not a game runs,
    /// so a silent sampler means the link is gone even if adb still lists the device.
    var isLive: Bool { latestSys != nil }

    private var streamsStarted: Date?

    // MARK: - Connection

    func start() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                await self?.ensureStreams()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        stopStreams()
    }

    private func stopStreams() {
        logStream?.stop()
        pollStream?.stop()
        logStream = nil
        pollStream = nil
    }

    /// Restarts whichever stream died. The headset's low-memory killer sometimes takes
    /// down the USB service mid-game, and Wi-Fi drops while the headset sleeps, so
    /// disconnects are expected and handled here.
    private func ensureStreams() async {
        guard ADB.path != nil else { link = .noADB; return }
        // Over Wi-Fi a vanished headset leaves adb streams hanging instead of exiting.
        if pollStream != nil, let started = streamsStarted,
           Date().timeIntervalSince(max(started, sys.last?.time ?? started)) > 12 {
            stopStreams()
            if let serial, serial.contains(":") { await ADB.run(["disconnect", serial], timeout: 3) }
        }
        if logStream != nil && pollStream != nil { return }
        var found = await findQuest()
        if found == nil, let address = wifiAddress, Date().timeIntervalSince(lastConnectAttempt) > 6 {
            lastConnectAttempt = Date()
            // A dropped link can stay listed as "offline", and connect then reports
            // "already connected" without reviving it.
            await ADB.run(["disconnect", address], timeout: 3)
            await ADB.run(["connect", address], timeout: 5)
            found = await findQuest()
        }
        guard let found else {
            serial = nil
            link = .searching
            stopStreams()
            return
        }
        serial = found
        link = .connected(found)

        if logStream == nil {
            logStream = LineStream(
                args: ["-s", found, "logcat", "-v", "raw", "-T", "1", "VrApi:I", "*:S"],
                onLine: { [weak self] in self?.handleVrLine($0) },
                onExit: { [weak self] in self?.logStream = nil })
        }
        if pollStream == nil {
            streamsStarted = Date()
            pollStream = LineStream(
                args: ["-s", found, "shell", Self.samplerScript],
                onLine: { [weak self] in self?.handleSysLine($0) },
                onExit: { [weak self] in self?.pollStream = nil })
        }
    }

    /// Picks the headset among the attached devices. The same headset shows up twice while
    /// both the cable and Wi-Fi are connected; USB wins because it is faster.
    private func findQuest() async -> String? {
        let result = await ADB.run(["devices", "-l"], timeout: 5)
        let devices = result.output.split(separator: "\n").compactMap { line -> (serial: String, quest: Bool)? in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, fields[1] == "device" else { return nil }
            return (String(fields[0]), line.contains("model:Quest"))
        }
        let ranked = devices.sorted { a, b in
            if a.quest != b.quest { return a.quest }
            return !a.serial.contains(":") && b.serial.contains(":")
        }
        return ranked.first?.serial
    }

    // MARK: - Wi-Fi

    /// Switches the USB-connected headset's adb to TCP and connects to it over Wi-Fi, so the
    /// cable can be unplugged. Horizon OS turns TCP mode off again on reboot.
    func enableWifi() async {
        await perform { serial in
            guard !serial.contains(":") else { return }
            status = "Reading the headset's Wi-Fi address…"
            let ipOutput = await ADB.shell(serial, "ip -f inet addr show wlan0").output
            guard let ip = Self.parseInetAddress(ipOutput) else {
                status = "The headset has no Wi-Fi address. Is it on Wi-Fi?"
                return
            }
            status = "Switching adb to Wi-Fi…"
            _ = await ADB.run(["-s", serial, "tcpip", "\(Self.wifiPort)"], timeout: 10)
            try? await Task.sleep(for: .seconds(2))
            let address = "\(ip):\(Self.wifiPort)"
            if await connectWifi(address) {
                status = "Wi-Fi ready at \(address). You can unplug the cable."
            } else {
                status = "adb is listening on Wi-Fi, but \(address) did not answer. Is this Mac on the same network?"
            }
        }
    }

    /// Connects to a headset whose adb already listens on Wi-Fi (enabled earlier over USB).
    func connect(to input: String) async {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        let address = trimmed.contains(":") ? trimmed : "\(trimmed):\(Self.wifiPort)"
        status = "Connecting to \(address)…"
        if await connectWifi(address) {
            status = "Connected over Wi-Fi to \(address)."
        } else {
            status = "\(address) did not answer. Wi-Fi adb is off after every headset reboot: connect the cable once and press Enable Wi-Fi."
        }
    }

    /// Disconnects Wi-Fi and stops reconnecting to the saved address.
    func forgetWifi() async {
        if let address = wifiAddress { await ADB.run(["disconnect", address], timeout: 5) }
        wifiAddress = nil
        UserDefaults.standard.removeObject(forKey: Self.wifiAddressKey)
        if link.isWifi { stopStreams() }
        status = "Wi-Fi address forgotten."
    }

    private func connectWifi(_ address: String) async -> Bool {
        let output = await ADB.run(["connect", address], timeout: 8).output
        guard output.contains("connected to") else { return false }
        wifiAddress = address
        UserDefaults.standard.set(address, forKey: Self.wifiAddressKey)
        return true
    }

    /// Extracts the IPv4 address from `ip -f inet addr show` output ("inet 192.168.4.42/24 …").
    static func parseInetAddress(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if let i = fields.firstIndex(of: "inet"), i + 1 < fields.count {
                return fields[i + 1].split(separator: "/").first.map(String.init)
            }
        }
        return nil
    }

    /// Runs on the headset. Uses only shell builtins except `sleep` and a once-a-minute
    /// `dumpsys battery`, so it costs next to nothing while a game is running.
    private static let samplerScript = """
    K=/sys/class/kgsl/kgsl-3d0; n=0; \
    while :; do \
      read c < $K/clock_mhz; read b < $K/gpu_busy_percentage; read t < $K/temp; \
      while read k v u; do case $k in MemAvailable:) a=$v;; SwapTotal:) st=$v;; SwapFree:) sf=$v;; esac; done < /proc/meminfo; \
      echo "S $c ${b%% *} $t $a $((st-sf))"; \
      if [ $((n % 30)) -eq 0 ]; then dumpsys battery | while read k v; do [ "$k" = level: ] && echo "B $v"; done; fi; \
      n=$((n+1)); sleep 2; \
    done
    """

    // MARK: - Parsing

    private func handleVrLine(_ line: String) {
        guard let sample = Self.parseVr(line) else { return }
        vr.append(sample)
        trim(&vr)
    }

    private func handleSysLine(_ line: String) {
        let f = line.split(separator: " ")
        if f.first == "B", f.count == 2 {
            battery = Int(f[1])
            return
        }
        guard f.first == "S", f.count == 6,
              let mhz = Double(f[1]), let busyPct = Double(f[2]), let temp = Double(f[3]),
              let avail = Double(f[4]), let swap = Double(f[5]) else { return }
        sys.append(SysSample(time: Date(), gpuMHz: mhz, gpuBusy: busyPct, gpuTempC: temp / 1000,
                             memAvailMB: avail / 1024, swapUsedMB: swap / 1024))
        trim(&sys)
    }

    private func trim<T: Timed>(_ samples: inout [T]) {
        let cutoff = Date().addingTimeInterval(-Self.window)
        if let first = samples.first, first.time < cutoff {
            samples.removeAll { $0.time < cutoff }
        }
    }

    /// Parses e.g. "FPS=72/90,...,CPU4/GPU=6/7,2208/690MHz,...,App=8.44ms,...,GPU%=0.95,...".
    static func parseVr(_ line: String) -> VrSample? {
        guard line.hasPrefix("FPS=") else { return nil }
        var fields: [String: Substring] = [:]
        var previousKey = ""
        for token in line.split(separator: ",") {
            if let eq = token.firstIndex(of: "=") {
                previousKey = String(token[..<eq])
                fields[previousKey] = token[token.index(after: eq)...]
            } else if previousKey.hasPrefix("CPU"), previousKey.hasSuffix("/GPU") {
                fields["clocks"] = token
            }
        }

        var s = VrSample(time: Date())
        if let fps = fields["FPS"] {
            let parts = fps.split(separator: "/")
            s.fps = number(parts.first) ?? 0
            s.targetFps = number(parts.dropFirst().first) ?? 0
        }
        s.appMs = number(fields["App"])
        s.stale = number(fields["Stale"]).map { Int($0) }
        s.freeMB = number(fields["Free"])
        s.gpuUtil = number(fields["GPU%"]).map { $0 * 100 }
        s.cpuUtil = number(fields["CPU%"]).map { $0 * 100 }
        if let levels = fields.first(where: { $0.key.hasPrefix("CPU") && $0.key.hasSuffix("/GPU") })?.value {
            let parts = levels.split(separator: "/")
            s.cpuLevel = number(parts.first).map { Int($0) }
            s.gpuLevel = number(parts.dropFirst().first).map { Int($0) }
        }
        if let clocks = fields["clocks"] {
            let parts = clocks.split(separator: "/")
            s.cpuMHz = number(parts.first)
            s.gpuMHz = number(parts.dropFirst().first)
        }
        return s
    }

    private static func number(_ text: Substring?) -> Double? {
        guard let text else { return nil }
        return Double(text.prefix { $0.isNumber || $0 == "." })
    }

    // MARK: - Actions

    private func perform(_ work: (String) async -> Void) async {
        guard let serial, !busy else { return }
        busy = true
        defer { busy = false }
        await work(serial)
    }

    func apply(_ tuning: Tuning, label: String = "Settings") async {
        await perform { serial in
            let result = await ADB.shell(serial, tuning.setpropCommand)
            if result.status == 0 {
                headsetTuning = tuning
                status = "\(label) applied. Texture size needs a game restart."
            } else {
                status = "Apply failed: \(result.output)"
            }
        }
    }

    func readTuning() async -> Tuning? {
        guard let serial else { return nil }
        let cmd = Tuning.propertyNames.map { "echo \"\($0)=$(getprop debug.oculus.\($0))\"" }.joined(separator: "; ")
        let output = await ADB.shell(serial, cmd).output
        var values: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            if kv.count == 2, let v = Int(kv[1].trimmingCharacters(in: .whitespaces)) { values[String(kv[0])] = v }
        }
        guard !values.isEmpty else {
            headsetTuning = nil
            return nil
        }
        var t = Tuning()
        if let v = values["gpuLevel"] { t.gpuLevel = min(max(v, 0), 7) }
        if let v = values["cpuLevel"] { t.cpuLevel = min(max(v, 0), 6) }
        if let v = values["refreshRate"] { t.refreshRate = v }
        if let v = values["foveation.level"] { t.foveation = min(max(v, 0), 4) }
        if let v = values["textureWidth"] { t.textureWidth = v }
        if let v = values["textureHeight"] { t.textureHeight = v }
        headsetTuning = t
        return t
    }

    func resetTuning() async {
        await perform { serial in
            let cmd = Tuning.propertyNames.map { "setprop debug.oculus.\($0) ''" }.joined(separator: "; ")
            _ = await ADB.shell(serial, cmd)
            headsetTuning = nil
            status = "Overrides cleared. The game picks its own levels again."
        }
    }

    /// Reads the recording settings; unset properties mean the system defaults.
    func readVideoCapture() async -> VideoCapture? {
        guard let serial else { return nil }
        let cmd = VideoCapture.propertyNames.map { "echo \"\($0)=$(getprop debug.oculus.\($0))\"" }.joined(separator: "; ")
        let result = await ADB.shell(serial, cmd)
        guard result.status == 0 else { return nil }
        var values: [String: Int] = [:]
        for line in result.output.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            if kv.count == 2, let v = Int(kv[1].trimmingCharacters(in: .whitespaces)) { values[String(kv[0])] = v }
        }
        var c = VideoCapture()
        if let v = values["capture.width"], v > 0 { c.width = v }
        if let v = values["capture.height"], v > 0 { c.height = v }
        if let v = values["capture.bitrate"], v > 0 { c.bitrate = v }
        if let v = values["fullRateCapture"] { c.fullRate = v == 1 }
        headsetVideoCapture = c
        return c
    }

    func applyVideoCapture(_ capture: VideoCapture) async {
        await perform { serial in
            let result = await ADB.shell(serial, capture.setpropCommand)
            if result.status == 0 {
                headsetVideoCapture = capture
                status = "Video capture set to \(capture.width)×\(capture.height), \(capture.bitrate / 1_000_000) Mbit/s. Applies to the next recording."
            } else {
                status = "Video capture settings failed: \(result.output)"
            }
        }
    }

    func resetVideoCapture() async {
        await perform { serial in
            let cmd = VideoCapture.propertyNames.map { "setprop debug.oculus.\($0) ''" }.joined(separator: "; ")
            _ = await ADB.shell(serial, cmd)
            headsetVideoCapture = VideoCapture()
            status = "Video capture back to the system defaults (1024×1024, 5 Mbit/s, half rate)."
        }
    }

    func loadGames() async {
        guard let serial else { return }
        let output = await ADB.shell(serial, "pm list packages -3").output
        games = output.split(separator: "\n")
            .map { $0.replacingOccurrences(of: "package:", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("com.meta.shell.env.") }
            .sorted()
        if !games.contains(game), games.contains(Self.defaultGame) { game = Self.defaultGame }
    }

    func restartGame() async {
        await perform { serial in
            let g = game
            _ = await ADB.shell(serial, "am force-stop \(g); sleep 1; monkey -p \(g) -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1")
            status = "Restarted \(g)."
        }
    }

    /// Optionally reboots, applies the tuning, stops everything that is not needed and launches the game.
    func boost(reboot: Bool, tuning: Tuning) async {
        await perform { serial in
            let g = game
            let before = await memoryLine(serial)

            // A reboot turns Wi-Fi adb off, so the app could not reach the headset afterwards.
            if reboot, serial.contains(":") {
                status = "Reboot needs the USB cable: Wi-Fi adb is off after a reboot."
                return
            }
            if reboot {
                status = "Rebooting headset…"
                _ = await ADB.run(["-s", serial, "reboot"])
                stopStreams()
                guard await waitForBoot(serial) else {
                    status = "Headset did not finish booting in 3 minutes."
                    return
                }
                status = "Booted, letting the VR shell settle…"
                try? await Task.sleep(for: .seconds(25))
            }

            status = "Applying settings…"
            if await ADB.shell(serial, tuning.setpropCommand).status == 0 { headsetTuning = tuning }

            status = "Stopping apps…"
            let thirdParty = await ADB.shell(serial, "pm list packages -3").output
                .split(separator: "\n")
                .map { $0.replacingOccurrences(of: "package:", with: "").trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != g && !$0.hasPrefix("com.meta.shell.env.") }
            let targets = thirdParty + nonEssentialMetaApps
            let stopCmd = (["am force-stop \(g)"] + targets.map { "am force-stop \($0) 2>/dev/null" } + ["am kill-all"])
                .joined(separator: "; ")
            _ = await ADB.shell(serial, stopCmd)
            try? await Task.sleep(for: .seconds(3))
            let after = await memoryLine(serial)

            _ = await ADB.shell(serial, "monkey -p \(g) -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1")
            status = "Stopped \(targets.count) apps. Before: \(before). After: \(after). Launched \(g)."
        }
    }

    // MARK: - Screenshots

    func capture(_ mode: CaptureMode) async {
        guard let serial, !capturing else { return }
        capturing = true
        defer { capturing = false }

        let folder = Self.captureFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        switch mode {
        case .display:
            status = "Capturing display…"
            let result = await ADB.runData(["-s", serial, "exec-out", "screencap", "-p"])
            guard result.status == 0, result.data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
                status = "Display capture failed."
                return
            }
            let url = folder.appendingPathComponent("Quest-\(stamp)-display.png")
            do {
                try result.data.write(to: url)
                lastCapture = url
                status = "Saved \(url.lastPathComponent)."
            } catch {
                status = "Could not save: \(error.localizedDescription)"
            }

        case .eye:
            status = "Capturing eye view…"
            let dir = "/sdcard/Oculus/Screenshots"
            let newest = "ls -t \(dir) 2>/dev/null | head -1"
            let before = await ADB.shell(serial, newest).output.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = await ADB.shell(serial, "am startservice -n com.oculus.metacam/.capture.CaptureService -a TAKE_SCREENSHOT")

            // The capture service writes the JPEG asynchronously; wait for a new file whose size has settled.
            var name = ""
            var lastSize = -1
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                let current = await ADB.shell(serial, newest).output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !current.isEmpty, current != before else { continue }
                let size = Int(await ADB.shell(serial, "stat -c %s '\(dir)/\(current)'").output
                    .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                if size > 0, size == lastSize { name = current; break }
                lastSize = size
            }
            guard !name.isEmpty else {
                status = "The headset did not produce a screenshot. Is it awake?"
                return
            }
            let url = folder.appendingPathComponent("Quest-\(stamp)-eye.jpg")
            let pull = await ADB.run(["-s", serial, "pull", "\(dir)/\(name)", url.path])
            if pull.status == 0 {
                lastCapture = url
                status = "Saved \(url.lastPathComponent)."
            } else {
                status = "Could not copy the screenshot: \(pull.output)"
            }
        }
    }

    private func waitForBoot(_ serial: String) async -> Bool {
        try? await Task.sleep(for: .seconds(5))
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            let r = await ADB.shell(serial, "getprop sys.boot_completed")
            if r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    private func memoryLine(_ serial: String) async -> String {
        let cmd = "while read k v u; do case $k in MemAvailable:) a=$v;; SwapTotal:) st=$v;; SwapFree:) sf=$v;; esac; done < /proc/meminfo; echo $((a/1024)) $(((st-sf)/1024))"
        let f = await ADB.shell(serial, cmd).output.split(separator: " ")
        guard f.count == 2 else { return "?" }
        return "\(f[0].trimmingCharacters(in: .whitespacesAndNewlines)) MB free, \(f[1].trimmingCharacters(in: .whitespacesAndNewlines)) MB swap"
    }
}
