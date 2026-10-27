import SwiftUI
import AppKit
import SwaprTransKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an accessory app: no Dock icon, stays in the menu bar
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("SwaprTrans MenuBar Daemon")
        ProcessInfo.processInfo.disableSuddenTermination()

        UpdateManager.shared.startBackgroundCheck()
    }
}

@main
struct SwaprTransApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var config = SwaprTransConfig.shared

    var body: some Scene {
        MenuBarExtra {
            StandaloneMenuBarPopup()
        } label: {
            if config.isEnabled && config.hasAccessibilityPermission {
                Image(systemName: "translate")
            } else {
                Image(systemName: "translate")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.secondary)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
