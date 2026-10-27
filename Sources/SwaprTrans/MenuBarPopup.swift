import SwiftUI
import AppKit
import SwaprTransKit

struct StandaloneMenuBarPopup: View {
    @ObservedObject var config = SwaprTransConfig.shared

    private var isActive: Bool { config.isEnabled && config.hasAccessibilityPermission }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "translate")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.gradient))

                VStack(alignment: .leading, spacing: 1) {
                    Text("SwaprTrans")
                        .font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isActive ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 7, height: 7)
                        Text(isActive ? "Active" : (config.hasAccessibilityPermission ? "Paused" : "Needs permission"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            // Accessibility permission banner if not granted
            if !config.hasAccessibilityPermission {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility access needed")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Used to read the selected text and replace it in place.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button("Grant") { config.requestPermission() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
            }

            SwaprTransSettingsView()

            Divider()

            // Footer
            HStack {
                Button("Project Page") {
                    if let url = URL(string: "https://github.com/Yohoa/swapr-trans") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Welcome Guide") { WelcomeWindowController.shared.show() }
                Spacer()
                Button("Quit SwaprTrans") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 400)
        .glassCard(.menu)
        .onAppear {
            config.checkPermission()
        }
    }
}
