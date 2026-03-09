import Foundation
import AppKit
import os

private let logger = Logger.speaky(category: "UpdateService")

struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let htmlUrl: String
    let assets: [Asset]

    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadUrl: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case assets
    }
}

@Observable
@MainActor
final class UpdateService {
    var availableUpdate: GitHubRelease?
    var updateDismissed = false

    private var checkTask: Task<Void, Never>?

    private static let checkInterval: TimeInterval = 4 * 60 * 60 // 4 hours
    private static let initialDelay: TimeInterval = 5
    private static let apiURL = URL(string: "https://api.github.com/repos/bedriyan/speaky/releases/latest")!

    var hasUpdate: Bool {
        availableUpdate != nil && !updateDismissed
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func startPeriodicChecks() {
        checkTask?.cancel()
        checkTask = Task {
            try? await Task.sleep(for: .seconds(Self.initialDelay))
            guard !Task.isCancelled else { return }
            await checkForUpdate()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.checkInterval))
                guard !Task.isCancelled else { return }
                await checkForUpdate()
            }
        }
    }

    func stopPeriodicChecks() {
        checkTask?.cancel()
        checkTask = nil
    }

    func checkForUpdate() async {
        do {
            var request = URLRequest(url: Self.apiURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                logger.warning("GitHub API returned non-200 status")
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remoteVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

            if Self.isNewer(remoteVersion, than: currentVersion) {
                availableUpdate = release
                updateDismissed = false
                logger.info("Update available: \(remoteVersion, privacy: .public) (current: \(self.currentVersion, privacy: .public))")
            } else {
                logger.debug("Up to date (\(self.currentVersion, privacy: .public))")
            }
        } catch {
            logger.warning("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func dismissUpdate() {
        updateDismissed = true
    }

    /// Returns the architecture-correct DMG download URL, or the release page as fallback.
    func downloadURL() -> URL? {
        guard let release = availableUpdate else { return nil }

        #if arch(arm64)
        let keyword = "Apple-Silicon"
        #else
        let keyword = "Intel"
        #endif

        if let asset = release.assets.first(where: { $0.name.contains(keyword) }) {
            return URL(string: asset.browserDownloadUrl)
        }
        return URL(string: release.htmlUrl)
    }

    /// Returns true if `remote` is a newer semver than `local`.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}
