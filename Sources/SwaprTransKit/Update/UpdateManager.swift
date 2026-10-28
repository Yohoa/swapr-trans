import Foundation
import AppKit
import CryptoKit
import Security

/// The `version.json` published with each release (as a release asset and on `main`).
public struct RemoteReleaseInfo: Codable, Sendable, Equatable {
    public let version: String
    public let date: String?
    public let notes: String?
    public let dmgUrl: String
    /// SHA-256 of the DMG, hex.
    public let sha256: String?
}

/// Checks this fork's GitHub releases for a newer version, and installs it in place.
///
/// Safety rules for installing:
/// - only DMGs from this repository's releases, over HTTPS, matching the published SHA-256;
/// - the new app must satisfy the running app's designated requirement (same bundle id, signed
///   by the same Yohoa Studio certificate), so a foreign build can't replace it and the
///   Accessibility permission carries over;
/// - the old app is moved aside, not deleted, until the new one is in place.
@MainActor
public final class UpdateManager: ObservableObject {
    public static let shared = UpdateManager()

    public enum Phase: Equatable {
        case idle
        case checking
        case available(RemoteReleaseInfo)
        case downloading(Double)
        case installing
        case upToDate
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle

    public nonisolated static let repository = "Yohoa/swapr-trans"
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    private static let endpoints = [
        "https://github.com/\(repository)/releases/latest/download/version.json",
        "https://raw.githubusercontent.com/\(repository)/main/version.json",
    ]
    private static let checkInterval: TimeInterval = 6 * 3600

    private var timer: Timer?
    private var progressObservation: NSKeyValueObservation?

    public var localVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    public var availableUpdate: RemoteReleaseInfo? {
        if case .available(let info) = phase { return info }
        return nil
    }

    private init() {}

    /// Checks shortly after launch, then every few hours.
    public func startBackgroundCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            Task { await self?.check(userInitiated: false) }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                Task { await self.check(userInitiated: false) }
            }
        }
    }

    public func check(userInitiated: Bool) async {
        switch phase {
        case .checking, .downloading, .installing: return
        // A background check doesn't overwrite a result the user is looking at
        case .available, .failed: if !userInitiated { return }
        default: break
        }
        phase = .checking

        var info: RemoteReleaseInfo?
        for endpoint in Self.endpoints {
            if let fetched = await Self.fetch(endpoint) {
                info = fetched
                break
            }
        }
        guard let info else {
            phase = userInitiated ? .failed("Couldn't reach GitHub to check for updates.") : .idle
            return
        }
        if Self.isVersion(info.version, newerThan: localVersion) {
            phase = .available(info)
        } else {
            phase = userInitiated ? .upToDate : .idle
        }
    }

    public func dismissMessage() {
        if case .available = phase { return }
        if case .downloading = phase { return }
        if phase == .installing { return }
        phase = .idle
    }

    private static func fetch(_ endpoint: String) async -> RemoteReleaseInfo? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
        request.setValue("SwaprTrans", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(RemoteReleaseInfo.self, from: data)
    }

    nonisolated static func isVersion(_ remote: String, newerThan local: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let r = parts(remote), l = parts(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0, b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Only release assets of this repository count as an update source.
    nonisolated static func isTrustedDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
            && url.path.hasPrefix("/\(repository)/releases/download/") && url.pathExtension == "dmg"
    }

    // MARK: - Install

    public func downloadAndInstall() {
        guard let info = availableUpdate else { return }
        guard let url = URL(string: info.dmgUrl), Self.isTrustedDownload(url) else {
            return fail("The update link isn't a release of \(Self.repository).")
        }
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app",
              !appURL.path.contains("/AppTranslocation/"), !appURL.path.hasPrefix("/Volumes/") else {
            return fail("Move SwaprTrans to the Applications folder first, then update.")
        }
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            return fail("No permission to replace \(appURL.path). Download the update manually.")
        }

        phase = .downloading(0)
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            // The downloaded file is removed when this handler returns: move it first
            var saved: URL?
            var problem: String?
            if let error {
                problem = "Download failed: \(error.localizedDescription)"
            } else if (response as? HTTPURLResponse)?.statusCode != 200 || tempURL == nil {
                problem = "Download failed."
            } else if let tempURL {
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwaprTrans-update-\(UUID().uuidString).dmg")
                do {
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    saved = dest
                } catch {
                    problem = "Couldn't save the update: \(error.localizedDescription)"
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.progressObservation = nil
                    if let saved {
                        self.install(dmg: saved, info: info, appURL: appURL)
                    } else {
                        self.fail(problem ?? "Download failed.")
                    }
                }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if case .downloading = self?.phase { self?.phase = .downloading(fraction) }
                }
            }
        }
        task.resume()
    }

    private func install(dmg: URL, info: RemoteReleaseInfo, appURL: URL) {
        phase = .installing
        let localVersion = self.localVersion
        Task.detached(priority: .userInitiated) {
            let result = Self.prepare(dmg: dmg, info: info, localVersion: localVersion)
            try? FileManager.default.removeItem(at: dmg)
            await MainActor.run {
                switch result {
                case .failure(let error): self.fail(error.message)
                case .success(let staged): self.swapAndRelaunch(staged: staged, appURL: appURL)
                }
            }
        }
    }

    struct UpdateError: Error { let message: String }

    /// Verifies the DMG, copies the app out of it and checks the copy. Returns the staged app.
    nonisolated private static func prepare(dmg: URL, info: RemoteReleaseInfo, localVersion: String) -> Result<URL, UpdateError> {
        guard let expected = info.sha256?.lowercased(), !expected.isEmpty else {
            return .failure(UpdateError(message: "The update has no checksum."))
        }
        guard let data = try? Data(contentsOf: dmg, options: .mappedIfSafe) else {
            return .failure(UpdateError(message: "Couldn't read the downloaded update."))
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            return .failure(UpdateError(message: "The download is corrupted (checksum mismatch)."))
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("SwaprTrans-update-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mnt")
        let staged = work.appendingPathComponent("SwaprTrans.app")
        do { try fm.createDirectory(at: mount, withIntermediateDirectories: true) } catch {
            return .failure(UpdateError(message: "Couldn't prepare the update."))
        }
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-mountpoint", mount.path, "-nobrowse", "-readonly", "-quiet"]) else {
            try? fm.removeItem(at: work)
            return .failure(UpdateError(message: "Couldn't open the update disk image."))
        }
        let copied = run("/usr/bin/ditto", [mount.appendingPathComponent("SwaprTrans.app").path, staged.path])
        _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"])
        guard copied else {
            try? fm.removeItem(at: work)
            return .failure(UpdateError(message: "The disk image doesn't contain SwaprTrans."))
        }

        let stagedVersion = Bundle(url: staged)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard isVersion(stagedVersion, newerThan: localVersion) else {
            try? fm.removeItem(at: work)
            return .failure(UpdateError(message: "The downloaded app isn't newer than this one."))
        }
        if let problem = signatureProblem(of: staged) {
            try? fm.removeItem(at: work)
            return .failure(UpdateError(message: problem))
        }
        return .success(staged)
    }

    /// nil when `app` is validly signed and satisfies the running app's designated requirement.
    nonisolated private static func signatureProblem(of app: URL) -> String? {
        var me: SecCode?
        var requirement: SecRequirement?
        var staticMe: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopyDesignatedRequirement(staticMe, [], &requirement) == errSecSuccess, let requirement else {
            return "Couldn't read this app's signature."
        }
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            return "The update isn't a signed app."
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(newCode, flags, requirement) == errSecSuccess else {
            return "The update isn't signed by Yohoa Studio, so it wasn't installed. Download it from the releases page instead."
        }
        return nil
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Hands the swap to a small script that waits for this process to quit, moves the old app aside,
    /// moves the new one in (restoring the old one if that fails) and relaunches.
    private func swapAndRelaunch(staged: URL, appURL: URL) {
        let script = """
        #!/bin/bash
        PID="$1"; NEW="$2"; TARGET="$3"; WORK="$4"
        for i in $(seq 1 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        OLD="$WORK/previous.app"
        if mv "$TARGET" "$OLD"; then
            if ditto "$NEW" "$TARGET"; then
                rm -rf "$WORK"
            else
                rm -rf "$TARGET"; mv "$OLD" "$TARGET"
            fi
        fi
        open "$TARGET"
        """
        let work = staged.deletingLastPathComponent()
        let scriptURL = work.appendingPathComponent("install.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, appURL.path, work.path]
            try p.run()
        } catch {
            try? FileManager.default.removeItem(at: work)
            return fail("Couldn't start the installer: \(error.localizedDescription)")
        }
        NSApp.terminate(nil)
    }

    private func fail(_ message: String) {
        phase = .failed(message)
    }
}
