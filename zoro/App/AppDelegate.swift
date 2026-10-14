import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { Self.activateMainWindow() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        PiSessions.shared.stopAll()
        PiSettings.shared.cancel()
        ConversationStore.shared.persistNow()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.activateMainWindow()
        return true
    }
    static func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain { window.makeKeyAndOrderFront(nil) }
    }
}
