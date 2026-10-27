import Foundation
import AppKit
import SwiftUI

public struct RemoteReleaseInfo: Codable, Sendable {
    public let version: String
    public let commit: String
    public let date: String?
    public let message: String?
    public let dmgUrl: String

    public init(version: String, commit: String, date: String? = nil, message: String? = nil, dmgUrl: String) {
        self.version = version
        self.commit = commit
        self.date = date
        self.message = message
        self.dmgUrl = dmgUrl
    }
}

@MainActor
public final class UpdateManager: NSObject, ObservableObject {
    public static let shared = UpdateManager()

    @Published public var isChecking: Bool = false
    @Published public var hasUpdate: Bool = false
    @Published public var isDownloading: Bool = false
    @Published public var downloadProgress: Double = 0.0
    @Published public var updateError: String? = nil
    @Published public var remoteInfo: RemoteReleaseInfo? = nil

    private var checkTimer: Timer?
    private var downloadTask: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    private let updateEndpoints: [String] = [
        "https://github.com/linrol/swapr-trans/releases/latest/download/version.json",
        "https://raw.githubusercontent.com/linrol/swapr-trans/main/version.json"
    ]

    public var localVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.1"
    }

    public var localCommit: String {
        Bundle.main.infoDictionary?["GitCommit"] as? String ?? ""
    }

    public var localCommitDate: String {
        Bundle.main.infoDictionary?["GitCommitDate"] as? String ?? ""
    }

    public var localCommitMessage: String {
        Bundle.main.infoDictionary?["GitCommitMessage"] as? String ?? ""
    }

    private override init() {
        super.init()
    }

    /// Schedule background update check on app launch and periodic intervals
    public func startBackgroundCheck() {
        // Initial check 3 seconds after launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            Task { @MainActor in
                await self?.checkForUpdates(silent: true)
            }
        }

        // Periodic check every 4 hours
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForUpdates(silent: true)
            }
        }
    }

    /// Check remote endpoints for newer version or commit
    public func checkForUpdates(silent: Bool = false) async {
        guard !isChecking, !isDownloading else { return }
        isChecking = true
        updateError = nil

        defer {
            isChecking = false
        }

        for endpoint in updateEndpoints {
            guard let url = URL(string: endpoint) else { continue }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 6.0
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 else {
                    continue
                }

                let decoder = JSONDecoder()
                let info = try decoder.decode(RemoteReleaseInfo.self, from: data)

                // Version compare: check semantic version or commit difference
                let isNewerVersion = isRemoteVersionNewer(remote: info.version, local: self.localVersion)
                let isNewerCommit = !self.localCommit.isEmpty && !info.commit.isEmpty && info.commit != self.localCommit

                if isNewerVersion || (info.version == self.localVersion && isNewerCommit) {
                    self.remoteInfo = info
                    self.hasUpdate = true
                } else {
                    self.hasUpdate = false
                    self.remoteInfo = nil
                }
                return
            } catch {
                continue
            }
        }

        if !silent && !hasUpdate {
            updateError = "Already up to date (v\(localVersion))"
        }
    }

    private func isRemoteVersionNewer(remote: String, local: String) -> Bool {
        let rParts = remote.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").compactMap { Int($0) }
        let lParts = local.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(rParts.count, lParts.count) {
            let rVal = i < rParts.count ? rParts[i] : 0
            let lVal = i < lParts.count ? lParts[i] : 0
            if rVal > lVal { return true }
            if rVal < lVal { return false }
        }
        return false
    }

    /// Download latest DMG and perform in-place replacement and restart
    public func downloadAndInstallUpdate() {
        guard let info = remoteInfo, let url = URL(string: info.dmgUrl), !isDownloading else { return }

        isDownloading = true
        downloadProgress = 0.0
        updateError = nil

        let tempDmgPath = "/tmp/SwaprTrans_update.dmg"
        try? FileManager.default.removeItem(atPath: tempDmgPath)

        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: url) { [weak self] tempUrl, _, error in
            Task { @MainActor in
                guard let self = self else { return }
                self.isDownloading = false

                if let error = error {
                    self.updateError = "Download failed: \(error.localizedDescription)"
                    return
                }

                guard let tempUrl = tempUrl else {
                    self.updateError = "Download failed: invalid source"
                    return
                }

                do {
                    try? FileManager.default.removeItem(atPath: tempDmgPath)
                    try FileManager.default.moveItem(at: tempUrl, to: URL(fileURLWithPath: tempDmgPath))
                    self.performAppReplacement()
                } catch {
                    self.updateError = "Failed to save installer: \(error.localizedDescription)"
                }
            }
        }

        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor in
                self?.downloadProgress = progress.fractionCompleted
            }
        }

        self.downloadTask = task
        task.resume()
    }

    /// Spawn a detached script to mount DMG, replace running app bundle, re-sign if possible, and relaunch
    private func performAppReplacement() {
        let scriptPath = "/tmp/swapr_trans_updater.sh"

        let bundlePath = Bundle.main.bundlePath
        let targetAppPath: String
        if bundlePath.hasSuffix(".app") {
            targetAppPath = bundlePath
        } else {
            targetAppPath = "/Applications/SwaprTrans.app"
        }

        let scriptContent = """
        #!/bin/bash
        TARGET_APP="\(targetAppPath)"
        sleep 0.5
        for i in {1..25}; do
            if ! pgrep -x SwaprTrans >/dev/null; then break; fi
            sleep 0.2
        done

        TMP_MOUNT="/tmp/SwaprTrans_mount_$$"
        mkdir -p "$TMP_MOUNT"
        hdiutil attach "/tmp/SwaprTrans_update.dmg" -mountpoint "$TMP_MOUNT" -nobrowse -quiet

        if [ -d "$TMP_MOUNT/SwaprTrans.app" ]; then
            rm -rf "$TARGET_APP"
            cp -R "$TMP_MOUNT/SwaprTrans.app" "$TARGET_APP"

            # Re-apply designated requirement code signature if developer certificate exists on this machine
            DR_REQ='designated => identifier "com.linrol.SwaprTrans"'
            if security find-identity -v -p codesigning 2>/dev/null | grep -q "Teams Wake Dev"; then
                codesign --force --deep -r="$DR_REQ" --sign "Teams Wake Dev" "$TARGET_APP" 2>/dev/null || true
            elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
                IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -n 1 | awk -F '"' '{print $2}')
                codesign --force --deep -r="$DR_REQ" --sign "$IDENTITY" "$TARGET_APP" 2>/dev/null || true
            fi

            # Clean quarantine attributes to prevent Gatekeeper block
            xattr -cr "$TARGET_APP"
        fi

        hdiutil detach "$TMP_MOUNT" -quiet 2>/dev/null || true
        rm -rf "$TMP_MOUNT"
        rm -f "/tmp/SwaprTrans_update.dmg"
        rm -f "$0"

        open "$TARGET_APP"
        """

        do {
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let perms = [FileAttributeKey.posixPermissions: 0o755]
            try FileManager.default.setAttributes(perms, ofItemAtPath: scriptPath)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
            try process.run()

            // Gracefully terminate this application so the updater script can take over
            NSApplication.shared.terminate(nil)
        } catch {
            updateError = "Failed to launch updater: \(error.localizedDescription)"
        }
    }
}
