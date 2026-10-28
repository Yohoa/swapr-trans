import SwiftUI
import AppKit
import SwaprTransKit

struct StandaloneMenuBarPopup: View {
    @ObservedObject var config = SwaprTransConfig.shared
    @ObservedObject var updates = UpdateManager.shared

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

            UpdateBanner(updates: updates)

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
                Button("v\(updates.localVersion)") {
                    Task { await updates.check(userInitiated: true) }
                }
                .help("Check for updates")
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

/// Shows an available update (with Update & Restart), download/install progress, or the result of a check.
struct UpdateBanner: View {
    @ObservedObject var updates: UpdateManager

    var body: some View {
        switch updates.phase {
        case .idle:
            EmptyView()
        case .checking:
            row(icon: "arrow.triangle.2.circlepath", tint: .secondary, title: "Checking for updates…") {
                ProgressView().controlSize(.small)
            }
        case .upToDate:
            row(icon: "checkmark.circle.fill", tint: .green, title: "SwaprTrans is up to date (v\(updates.localVersion))") { closeButton }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                row(icon: "exclamationmark.triangle.fill", tint: .orange, title: message) { closeButton }
                Button("Open Releases Page") { NSWorkspace.shared.open(UpdateManager.releasesPage) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
        case .available(let info):
            VStack(alignment: .leading, spacing: 6) {
                row(icon: "arrow.down.circle.fill", tint: .accentColor, title: "SwaprTrans \(info.version) is available") {
                    Button("Update & Restart") { updates.downloadAndInstall() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
                if let notes = info.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.12)))
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                row(icon: "arrow.down.circle", tint: .accentColor, title: "Downloading update…") { EmptyView() }
                ProgressView(value: fraction).progressViewStyle(.linear)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.12)))
        case .installing:
            row(icon: "shippingbox", tint: .accentColor, title: "Installing… SwaprTrans will restart.") {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var closeButton: some View {
        Button { updates.dismissMessage() } label: {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    private func row<Trailing: View>(icon: String, tint: Color, title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing()
        }
    }
}
