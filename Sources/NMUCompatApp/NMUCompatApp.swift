import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct NMUCompatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("NMUCompat") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1000, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
