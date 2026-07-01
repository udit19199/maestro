//
//  AppDelegate.swift
//  zoro
//
//  Created by Udit Agarwal on 01/07/26.
//

import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let hideDock = UserDefaults.standard.object(forKey: "hide_dock_icon") as? Bool ?? true
        Self.applyDockVisibility(hide: hideDock)

        if UserDefaults.standard.object(forKey: "launch_at_login_configured") == nil {
            UserDefaults.standard.set(true, forKey: "launch_at_login_configured")
            if SMAppService.mainApp.status != .enabled {
                try? SMAppService.mainApp.register()
            }
        }

        BriefingService.shared.startBackgroundRefresh()
    }

    static func applyDockVisibility(hide: Bool) {
        if hide {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    static func activateMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
        let hideDock = UserDefaults.standard.object(forKey: "hide_dock_icon") as? Bool ?? true
        if hideDock {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
