import AppKit
import Foundation

/// Browses the headset's storage over adb and moves files between it and this Mac.
/// Uses whichever link the dashboard has (USB or Wi-Fi).
@MainActor
final class FileBrowser: ObservableObject {
    static let shared = FileBrowser()

    struct Entry: Identifiable, Hashable {
        let name: String
        let isFolder: Bool
        let size: Int64
        let modified: Date
        var id: String { name }
        var isHidden: Bool { name.hasPrefix(".") }
    }

    struct Place: Identifiable, Hashable {
        let title: String
        let systemImage: String
        let path: String
        var id: String { path }
    }

    static let places = [
        Place(title: "Internal storage", systemImage: "internaldrive", path: "/sdcard"),
        Place(title: "Downloads", systemImage: "arrow.down.circle", path: "/sdcard/Download"),
        Place(title: "Screenshots", systemImage: "camera", path: "/sdcard/Oculus/Screenshots"),
        Place(title: "Videos", systemImage: "video", path: "/sdcard/Oculus/VideoShots"),
        Place(title: "Movies", systemImage: "film", path: "/sdcard/Movies"),
        Place(title: "App data", systemImage: "shippingbox", path: "/sdcard/Android/data"),
        Place(title: "App OBB", systemImage: "archivebox", path: "/sdcard/Android/obb"),
        Place(title: "Temp", systemImage: "clock", path: "/data/local/tmp"),
    ]

    struct Transfer {
        enum Direction { case download, upload }
        let direction: Direction
        let count: Int
        var index = 0
        var current = ""
        var done: Int64 = 0
        let total: Int64?
    }

    @Published private(set) var path = "/sdcard"
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var transfer: Transfer?
    @Published private(set) var message = ""
    @Published private(set) var freeSpace: String?
    /// Local copies from the last finished download, for "Show in Finder".
    @Published private(set) var lastDownload: [URL] = []
    @Published var showHidden = false

    private var history: [String] = []
    private let running = RunningProcess()
    private var cancelled = false

    private static let downloadFolderKey = "downloadFolder"

    var canGoBack: Bool { !history.isEmpty }
    var canGoUp: Bool { path != "/" }
    var busy: Bool { transfer != nil }

    private var serial: String? {
        if case .connected(let serial) = QuestModel.shared.link { return serial }
        return nil
    }

    // MARK: Navigation

    func open(_ newPath: String) async {
        let target = Self.normalize(newPath)
        if target != path { history.append(path) }
        path = target
        await reload()
    }

    func open(_ entry: Entry) async {
        if entry.isFolder {
            await open(Self.join(path, entry.name))
        } else {
            await openOnMac(entry)
        }
    }

    func back() async {
        guard let previous = history.popLast() else { return }
        path = previous
        await reload()
    }

    func up() async {
        await open((path as NSString).deletingLastPathComponent)
    }

    func reload() async {
        guard let serial else {
            entries = []
            error = nil
            return
        }
        loading = true
        defer { loading = false }
        // One stat call for the whole folder; -L so links to folders (such as /sdcard) list as folders.
        // A glob that matches nothing stays literal and stat drops it with an error on stderr.
        let command = "cd -- \(Self.quote(path)) || exit 3; stat -L -c '%F|%s|%Y|%n' -- * .* 2>/dev/null; true"
        async let listing = ADB.shell(serial, command)
        async let df = ADB.shell(serial, "df -k \(Self.quote(path)) | tail -1")
        let result = await listing
        if result.status == 3 {
            entries = []
            error = result.output.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "Cannot open this folder."
        } else {
            entries = Self.parseListing(result.output)
            error = nil
        }
        freeSpace = Self.parseFree(await df.output)
    }

    // MARK: Transfers

    /// Asks for a Mac folder and downloads the entries into it.
    func download(_ items: [Entry]) async {
        guard !items.isEmpty, !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        panel.message = "Choose where to save \(items.count == 1 ? items[0].name : "\(items.count) items")."
        panel.directoryURL = UserDefaults.standard.url(forKey: Self.downloadFolderKey)
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        UserDefaults.standard.set(folder, forKey: Self.downloadFolderKey)

        let copies = await pull(items, to: folder)
        if !copies.isEmpty { lastDownload = copies }
    }

    /// Downloads a file to a temporary folder and opens it with its default Mac app.
    func openOnMac(_ entry: Entry) async {
        guard !busy else { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuestTuner/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let copy = await pull([entry], to: folder).first {
            NSWorkspace.shared.open(copy)
        }
    }

    /// Asks for Mac files or folders and uploads them into the current headset folder.
    func chooseUpload() async {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Upload to \(path) on the headset."
        guard panel.runModal() == .OK else { return }
        await upload(panel.urls)
    }

    func upload(_ urls: [URL]) async {
        guard let serial, !urls.isEmpty, !busy else { return }
        lastDownload = []
        let folder = path
        var taken = Set(entries.map(\.name))
        let targets = urls.map { url -> String in
            let name = Self.uniqueName(url.lastPathComponent, taken: taken)
            taken.insert(name)
            return Self.join(folder, name)
        }
        let total = urls.reduce(Int64(0)) { $0 + Self.localBytes($1) }
        transfer = Transfer(direction: .upload, count: urls.count, total: total)
        cancelled = false
        var completed: Int64 = 0
        var failed: String?

        for (i, url) in urls.enumerated() {
            transfer?.index = i
            transfer?.current = url.lastPathComponent
            let remote = targets[i]
            let base = completed
            let poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { break }
                    let sent = await Self.remoteBytes(serial, [remote])
                    self?.transfer?.done = base + sent
                }
            }
            let result = await ADB.run(["-s", serial, "push", url.path, remote], started: { [running] in running.set($0) })
            poll.cancel()
            running.set(nil)
            if cancelled {
                // Drop the partial copy this upload created; nothing else is touched.
                _ = await ADB.shell(serial, "rm -rf -- \(Self.quote(remote))")
                break
            }
            if result.status != 0 {
                failed = Self.adbError(result.output)
                break
            }
            completed += Self.localBytes(url)
            transfer?.done = completed
        }

        transfer = nil
        if cancelled {
            message = "Upload cancelled."
        } else if let failed {
            message = "Upload failed: \(failed)"
        } else {
            message = "Uploaded \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items") (\(Self.bytes(completed)))."
        }
        if folder == path { await reload() }
    }

    func cancelTransfer() {
        cancelled = true
        running.terminate()
    }

    /// Copies the entries from the current folder into `folder`, never overwriting a Mac file.
    /// Returns the local copies that finished.
    private func pull(_ items: [Entry], to folder: URL) async -> [URL] {
        guard let serial else { return [] }
        lastDownload = []
        let remotes = items.map { Self.join(path, $0.name) }
        let total: Int64? = items.contains(where: \.isFolder)
            ? await Self.remoteBytes(serial, remotes)
            : items.reduce(0) { $0 + $1.size }
        transfer = Transfer(direction: .download, count: items.count, total: total)
        cancelled = false
        var completed: Int64 = 0
        var copies: [URL] = []
        var failed: String?

        for (i, item) in items.enumerated() {
            transfer?.index = i
            transfer?.current = item.name
            let local = Self.uniqueURL(folder.appendingPathComponent(item.name))
            let base = completed
            let poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { break }
                    self?.transfer?.done = base + Self.localBytes(local)
                }
            }
            // -a keeps the headset's modification times.
            let result = await ADB.run(["-s", serial, "pull", "-a", remotes[i], local.path], started: { [running] in running.set($0) })
            poll.cancel()
            running.set(nil)
            if cancelled {
                try? FileManager.default.removeItem(at: local)
                break
            }
            if result.status != 0 {
                failed = Self.adbError(result.output)
                break
            }
            completed += Self.localBytes(local)
            transfer?.done = completed
            copies.append(local)
        }

        transfer = nil
        if cancelled {
            message = "Download cancelled."
        } else if let failed {
            message = "Download failed: \(failed)"
        } else {
            message = "Downloaded \(items.count == 1 ? items[0].name : "\(items.count) items") (\(Self.bytes(completed)))."
        }
        return copies
    }

    // MARK: Changes

    func createFolder(named name: String) async {
        guard let serial, let name = Self.validName(name) else { return }
        let result = await ADB.shell(serial, "mkdir -- \(Self.quote(Self.join(path, name)))")
        message = result.status == 0 ? "Created \(name)." : "New folder failed: \(Self.adbError(result.output))"
        await reload()
    }

    func rename(_ entry: Entry, to name: String) async {
        guard let serial, let name = Self.validName(name), name != entry.name else { return }
        let from = Self.quote(Self.join(path, entry.name))
        let to = Self.quote(Self.join(path, name))
        // Refuse to replace an existing item.
        let result = await ADB.shell(serial, "[ -e \(to) ] && { echo 'An item with that name already exists'; exit 4; }; mv -- \(from) \(to)")
        message = result.status == 0 ? "Renamed to \(name)." : "Rename failed: \(Self.adbError(result.output))"
        await reload()
    }

    /// Deletes from the headset for good; the view confirms first.
    func delete(_ items: [Entry]) async {
        guard let serial, !items.isEmpty else { return }
        let targets = items.map { Self.quote(Self.join(path, $0.name)) }.joined(separator: " ")
        let result = await ADB.shell(serial, "rm -rf -- \(targets)")
        message = result.status == 0
            ? "Deleted \(items.count == 1 ? items[0].name : "\(items.count) items")."
            : "Delete failed: \(Self.adbError(result.output))"
        await reload()
    }

    // MARK: Helpers

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }

    static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let standard = (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed) as NSString
        return standard.standardizingPath.isEmpty ? "/" : standard.standardizingPath
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private static func validName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/") else { return nil }
        return trimmed
    }

    private static func parseListing(_ output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, let size = Int64(fields[1]), let seconds = TimeInterval(fields[2]) else { return nil }
            let name = String(fields[3])
            guard name != ".", name != ".." else { return nil }
            return Entry(name: name, isFolder: fields[0] == "directory", size: size,
                         modified: Date(timeIntervalSince1970: seconds))
        }
    }

    /// `df -k` last line: filesystem, 1K-blocks, used, available, use%, mount point.
    private static func parseFree(_ output: String) -> String? {
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 4, let total = Int64(fields[1]), let available = Int64(fields[3]) else { return nil }
        return "\(bytes(available * 1024)) free of \(bytes(total * 1024))"
    }

    /// adb's own message without the "adb: error:" prefix.
    private static func adbError(_ output: String) -> String {
        let line = output.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        return line.replacingOccurrences(of: "adb: error: ", with: "").trimmingCharacters(in: .whitespaces)
    }

    private static func remoteBytes(_ serial: String, _ paths: [String]) async -> Int64 {
        let list = paths.map(quote).joined(separator: " ")
        let output = await ADB.shell(serial, "find \(list) -type f -exec stat -c %s {} + 2>/dev/null").output
        return output.split(separator: "\n").reduce(0) { $0 + (Int64($1.trimmingCharacters(in: .whitespaces)) ?? 0) }
    }

    nonisolated private static func localBytes(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var sum: Int64 = 0
        for case let file as URL in walker {
            if let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true {
                sum += Int64(values.fileSize ?? 0)
            }
        }
        return sum
    }

    /// "name.ext", then "name 2.ext", "name 3.ext"… like Finder.
    private static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for n in 2... {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !taken.contains(candidate) { return candidate }
        }
        return name
    }

    private static func uniqueURL(_ url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        return folder.appendingPathComponent(uniqueName(url.lastPathComponent, taken: existing))
    }
}

/// The adb process of the transfer in flight, so Cancel can stop it from the main thread.
private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process?) { lock.withLock { self.process = process } }
    func terminate() { lock.withLock { if process?.isRunning == true { process?.terminate() } } }
}
