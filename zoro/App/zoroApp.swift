//
//  zoroApp.swift
//  zoro
//
//  Created by Udit Agarwal on 19/06/26.
//

import SwiftUI

@main
struct zoroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AppShell()
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    NotificationCenter.default.post(name: .zoroNewChat, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        MenuBarExtra("Zoro", systemImage: "bubble.left.and.bubble.right") {
            MenuBarContent()
        }

        Settings {
            SettingsView()
        }
    }
}

private struct MenuBarContent: View {
    var body: some View {
        Button("Open Zoro") {
            AppDelegate.activateMainWindow()
        }
        Button("New Chat") {
            NotificationCenter.default.post(name: .zoroNewChat, object: nil)
        }
        Divider()
        Button("Settings…") {
            openZoroSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

extension Notification.Name {
    static let zoroNewChat = Notification.Name("zoroNewChat")
}
