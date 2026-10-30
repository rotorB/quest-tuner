import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // applicationWillTerminate only runs on a normal quit; also stop the adb children on kill signals.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    LiveStream.shared.stop()
                    QuestModel.shared.stop()
                }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let path = ProcessInfo.processInfo.environment["QUESTTUNER_SNAPSHOT"] {
            Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
                MainActor.assumeIsolated { writeDashboardSnapshot(to: path, model: QuestModel.shared) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Kill the adb child processes so nothing keeps reading from the headset after quit.
        MainActor.assumeIsolated {
            LiveStream.shared.stop()
            QuestModel.shared.stop()
        }
    }
}

@main
struct QuestTunerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = QuestModel.shared

    var body: some Scene {
        Window("Quest Tuner", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear { model.start() }
        }
        .windowResizability(.contentMinSize)

        Window("Headset Files", id: "files") {
            FileBrowserView()
                .environmentObject(model)
        }
        .defaultSize(width: 920, height: 600)

        Window("Live View", id: "live") {
            LiveView()
                .environmentObject(model)
        }
        .defaultSize(width: 900, height: 820)
    }
}
