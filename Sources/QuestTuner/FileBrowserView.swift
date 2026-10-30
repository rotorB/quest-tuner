import SwiftUI

/// The "Headset Files" window: places on the left, the current folder as a table.
struct FileBrowserView: View {
    @EnvironmentObject private var model: QuestModel
    @StateObject private var browser = FileBrowser.shared
    @State private var selection = Set<FileBrowser.Entry.ID>()
    @State private var sortOrder = [KeyPathComparator(\FileBrowser.Entry.name)]
    @State private var pathField = ""
    @State private var place: FileBrowser.Place.ID?
    @State private var confirmDelete = false
    @State private var naming: Naming?
    @State private var nameField = ""
    @State private var dropTargeted = false

    private enum Naming: Identifiable {
        case newFolder
        case rename(FileBrowser.Entry)
        var id: String {
            switch self {
            case .newFolder: "new"
            case .rename(let entry): "rename:" + entry.name
            }
        }
    }

    private var connected: Bool {
        if case .connected = model.link { return true }
        return false
    }

    /// Folders first, each group in the table's sort order.
    private var rows: [FileBrowser.Entry] {
        let visible = browser.entries.filter { browser.showHidden || !$0.isHidden }
        let sorted = visible.sorted(using: sortOrder)
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    private var selected: [FileBrowser.Entry] {
        rows.filter { selection.contains($0.id) }
    }

    var body: some View {
        NavigationSplitView {
            List(FileBrowser.places, selection: $place) { place in
                Label(place.title, systemImage: place.systemImage).tag(place.id)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            if connected {
                VStack(spacing: 0) {
                    pathBar
                    Divider()
                    fileTable
                    Divider()
                    bottomBar
                }
            } else {
                ContentUnavailableView("Headset not connected", systemImage: "cable.connector.slash",
                                       description: Text("Connect over USB or Wi-Fi in the main window."))
            }
        }
        .navigationTitle((browser.path as NSString).lastPathComponent.isEmpty ? "/" : (browser.path as NSString).lastPathComponent)
        .navigationSubtitle(browser.path)
        .toolbar { toolbar }
        .frame(minWidth: 760, minHeight: 420)
        .task(id: model.link) { await browser.reload() }
        .onChange(of: place) { _, id in
            guard let id else { return }
            Task { await browser.open(id) }
        }
        .onChange(of: browser.path) { _, path in
            pathField = path
            selection = []
            if place != path { place = FileBrowser.places.contains { $0.path == path } ? path : nil }
        }
        .onAppear { pathField = browser.path }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                let items = selected
                Task { await browser.delete(items) }
            }
        } message: {
            Text("This removes them from the headset for good. It cannot be undone.")
        }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $nameField)
            Button(namingAction) {
                let name = nameField
                switch naming {
                case .newFolder: Task { await browser.createFolder(named: name) }
                case .rename(let entry): Task { await browser.rename(entry, to: name) }
                case nil: break
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Parts

    private var pathBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            TextField("Path on the headset", text: $pathField)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .onSubmit { Task { await browser.open(pathField) } }
            Toggle("Hidden", isOn: $browser.showHidden)
                .toggleStyle(.checkbox)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var fileTable: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                Label {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: entry.isFolder ? "folder.fill" : icon(for: entry.name))
                        .foregroundStyle(entry.isFolder ? Zone.neutral.color : .secondary)
                }
                .opacity(entry.isHidden ? 0.55 : 1)
            }
            TableColumn("Size", value: \.size) { entry in
                Text(entry.isFolder ? "—" : FileBrowser.bytes(entry.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90, max: 120)
            TableColumn("Modified", value: \.modified) { entry in
                Text(entry.modified, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150, max: 200)
        }
        .contextMenu(forSelectionType: FileBrowser.Entry.ID.self) { ids in
            let items = rows.filter { ids.contains($0.id) }
            if items.count == 1, let item = items.first {
                Button(item.isFolder ? "Open" : "Open on Mac") { Task { await browser.open(item) } }
                Button("Rename…") { startRename(item) }
                Divider()
            }
            if !items.isEmpty {
                Button("Download…") { Task { await browser.download(items) } }
                Divider()
                Button("Delete…", role: .destructive) {
                    selection = ids
                    confirmDelete = true
                }
            } else {
                Button("New Folder…") { startNewFolder() }
                Button("Upload…") { Task { await browser.chooseUpload() } }
            }
        } primaryAction: { ids in
            guard ids.count == 1, let item = rows.first(where: { ids.contains($0.id) }) else { return }
            Task { await browser.open(item) }
        }
        .onDeleteCommand { if !selection.isEmpty { confirmDelete = true } }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, !browser.busy else { return false }
            Task { await browser.upload(files) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Zone.neutral.color, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            } else if let error = browser.error {
                ContentUnavailableView("Cannot open folder", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if rows.isEmpty, !browser.loading {
                ContentUnavailableView("Empty folder", systemImage: "folder",
                                       description: Text("Drop files from Finder here to upload them."))
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if let transfer = browser.transfer {
                TransferProgress(transfer: transfer)
                Button("Cancel") { browser.cancelTransfer() }
                    .buttonStyle(PanelButtonStyle(kind: .secondary))
            } else {
                if browser.loading { ProgressView().controlSize(.small) }
                Text(browser.message.isEmpty ? summary : browser.message)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !browser.lastDownload.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(browser.lastDownload) }
                        .buttonStyle(PanelButtonStyle(kind: .secondary))
                }
                Spacer()
                if let free = browser.freeSpace { Text(free) }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { Task { await browser.back() } } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!browser.canGoBack || !connected)
                .keyboardShortcut("[", modifiers: .command)
            Button { Task { await browser.up() } } label: { Label("Enclosing folder", systemImage: "chevron.up") }
                .disabled(!browser.canGoUp || !connected)
                .keyboardShortcut(.upArrow, modifiers: .command)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { startNewFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .help("New folder")
            Button { Task { await browser.chooseUpload() } } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                .help("Upload files from this Mac")
                .disabled(browser.busy)
            Button { Task { await browser.download(selected) } } label: { Label("Download", systemImage: "square.and.arrow.down") }
                .help("Download the selection to this Mac")
                .disabled(selected.isEmpty || browser.busy)
            Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                .help("Delete the selection from the headset")
                .disabled(selected.isEmpty || browser.busy)
            Button { Task { await browser.reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh")
                .keyboardShortcut("r", modifiers: .command)
        }
    }

    // MARK: Actions and text

    private func startNewFolder() {
        nameField = "New Folder"
        naming = .newFolder
    }

    private func startRename(_ entry: FileBrowser.Entry) {
        nameField = entry.name
        naming = .rename(entry)
    }

    private var summary: String {
        let folders = rows.filter(\.isFolder).count
        let files = rows.count - folders
        return "\(folders) folder\(folders == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s")"
    }

    private var deleteTitle: String {
        let items = selected
        return items.count == 1 ? "Delete “\(items[0].name)” from the headset?" : "Delete \(items.count) items from the headset?"
    }

    private var namingTitle: String {
        if case .rename(let entry) = naming { return "Rename “\(entry.name)”" }
        return "New folder in \(browser.path)"
    }

    private var namingAction: String {
        if case .rename = naming { return "Rename" }
        return "Create"
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "bmp": "photo"
        case "mp4", "mov", "mkv", "webm", "avi": "film"
        case "mp3", "wav", "ogg", "m4a", "flac": "waveform"
        case "apk", "obb": "shippingbox"
        case "zip", "gz", "tar", "7z", "rar": "doc.zipper"
        case "txt", "log", "json", "xml", "ini", "cfg", "csv", "md": "doc.text"
        default: "doc"
        }
    }
}

private struct TransferProgress: View {
    let transfer: FileBrowser.Transfer

    var body: some View {
        let verb = transfer.direction == .download ? "Downloading" : "Uploading"
        let counter = transfer.count > 1 ? " (\(transfer.index + 1) of \(transfer.count))" : ""
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .download ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .foregroundStyle(Zone.neutral.color)
            Text("\(verb) \(transfer.current)\(counter)")
                .lineLimit(1)
                .truncationMode(.middle)
            if let total = transfer.total, total > 0 {
                ProgressView(value: Double(min(transfer.done, total)), total: Double(total))
                    .frame(minWidth: 120)
                Text("\(FileBrowser.bytes(transfer.done)) of \(FileBrowser.bytes(total))")
                    .monospacedDigit()
                    .fixedSize()
            } else {
                ProgressView().controlSize(.small)
                Spacer()
            }
        }
    }
}
