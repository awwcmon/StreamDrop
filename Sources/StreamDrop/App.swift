import AppKit
import SwiftUI

@main
struct Launcher {
    static func main() {
        EngineWorker.runIfRequested()
        StreamDropApp.main()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: DownloadStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.isBusy else { return .terminateNow }
        Task {
            await store.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
        return true
    }
}

struct StreamDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = DownloadStore()

    var body: some Scene {
        Window("StreamDrop", id: "main") {
            ContentView()
                .environmentObject(store)
                .tint(.purple)
                .frame(minWidth: 800, minHeight: 520)
                .onAppear { delegate.store = store }
        }
        .defaultSize(width: 960, height: 660)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Link…") {
                    NotificationCenter.default.post(name: Notification.Name("StreamDrop.addLink"), object: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }.keyboardShortcut("n")
                Button("Paste Link…") {
                    NotificationCenter.default.post(name: Notification.Name("StreamDrop.pasteLink"), object: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("Downloads") {
                Button("Pause All", action: store.pauseAll)
                    .disabled(!store.items.contains { $0.phase.isActive || $0.phase == .queued })
                Button("Resume All", action: store.resumeAll)
                    .disabled(!store.items.contains { $0.phase == .paused })
                Divider()
                Button("Choose Download Folder…", action: store.chooseDestination)
                Button("Clear Completed", action: store.clearCompleted)
                    .disabled(!store.items.contains { $0.phase == .completed })
            }
        }
        Settings {
            PreferencesView().environmentObject(store).tint(.purple)
        }
    }
}
