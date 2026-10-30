import AppKit
import SwiftUI

@main
struct VerificationLauncher {
    static func main() {
        EngineWorker.runIfRequested()
        VerificationApp.main()
    }
}

@MainActor
struct VerificationApp: App {
    @StateObject private var store: DownloadStore

    init() {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let model = DownloadStore(storageURL: directory.appendingPathComponent("ui-queue.json"))
        model.destinationURL = directory.appendingPathComponent("ui-media", isDirectory: true)
        _store = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        Window("StreamDrop Verification", id: "verification") {
            ContentView().environmentObject(store).frame(minWidth: 800, minHeight: 520)
        }
        .defaultSize(width: 960, height: 660)
        Settings { PreferencesView().environmentObject(store) }
    }
}
