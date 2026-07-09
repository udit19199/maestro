//
//  SettingsLauncher.swift
//  zoro
//

import AppKit

/// Opens the native Settings scene reliably from anywhere in the app.
///
/// Zoro runs as a menu-bar accessory by default (Dock icon hidden), so the standard
/// app menu and its "Settings… ⌘," item are not shown, and a freshly opened Settings
/// window can appear behind other apps. Activating the app first guarantees the window
/// becomes key and visible. Using the AppKit responder action (rather than the SwiftUI
/// `openSettings` environment action) keeps this working from the `MenuBarExtra` menu too.
@MainActor
func openZoroSettings() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
}
