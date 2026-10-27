import SwiftUI
import AppKit
import Combine
import SwaprTransKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an accessory app: no Dock icon, stays in the menu bar
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("SwaprTrans MenuBar Daemon")
        ProcessInfo.processInfo.disableSuddenTermination()
        statusController = StatusItemController()
        if !SwaprTransConfig.shared.hasOnboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { WelcomeWindowController.shared.show() }
        }
    }
}

@main
struct SwaprTransApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The menu bar item and its popup are AppKit (StatusItemController); SwiftUI needs at least one scene,
        // and a hidden MenuBarExtra is one without any window to open or restore
        MenuBarExtra("SwaprTrans", systemImage: "translate", isInserted: .constant(false)) { EmptyView() }
    }
}
