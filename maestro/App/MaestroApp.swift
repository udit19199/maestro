//
//  MaestroApp.swift
//  maestro
//
//  Created by Udit Agarwal on 19/06/26.
//

import SwiftUI

@main
struct MaestroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AppShell()
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { NotificationCenter.default.post(name: .maestroSettings, object: nil) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    NotificationCenter.default.post(name: .maestroNewChat, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        MenuBarExtra("Maestro", systemImage: "bubble.left.and.bubble.right") {
            MenuBarContent()
        }


    }
}

private struct MenuBarContent: View {
    var body: some View {
        Button("Open Maestro") {
            AppDelegate.activateMainWindow()
        }
        Button("New Chat") {
            NotificationCenter.default.post(name: .maestroNewChat, object: nil)
        }
        Divider()
        Button("Settings…") {
            AppDelegate.activateMainWindow()
            NotificationCenter.default.post(name: .maestroSettings, object: nil)
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
    static let maestroSettings = Notification.Name("maestroSettings")
    static let maestroNewChat = Notification.Name("maestroNewChat")
}
