import AppKit
import Foundation
import DoubaoVoiceHelperCore

public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case noReleasesFound(currentVersion: String)
    case updateAvailable(version: String, notes: String, downloadURL: URL?, releasePageURL: URL)
    case downloading(progress: Double)
    case installing
    case failed(error: String)
}

struct GitHubRelease: Codable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case assets
    }
}

struct GitHubAsset: Codable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

@MainActor
final class UpdateService: ObservableObject {
    @Published var state: UpdateState = .idle

    func checkForUpdates(currentVersion: String) async {
        state = .checking
        do {
            var request = URLRequest(url: AppSettings.gitHubReleasesAPIURL)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            request.setValue("DoubaoVoiceHelper", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                state = .failed(error: "无效的网络响应")
                return
            }

            if httpResponse.statusCode == 404 {
                state = .noReleasesFound(currentVersion: currentVersion)
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                state = .failed(error: "GitHub 响应异常 (HTTP \(httpResponse.statusCode))")
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remoteVersion = AppVersion(release.tagName)
            let localVersion = AppVersion(currentVersion)

            if remoteVersion > localVersion {
                let zipAsset = release.assets.first { $0.name.lowercased().hasSuffix(".zip") }
                let downloadURL = zipAsset.flatMap { URL(string: $0.browserDownloadUrl) }
                let releasePageURL = URL(string: release.htmlUrl) ?? AppSettings.gitHubReleasesPageURL
                state = .updateAvailable(
                    version: release.tagName,
                    notes: release.body ?? "",
                    downloadURL: downloadURL,
                    releasePageURL: releasePageURL
                )
            } else {
                state = .upToDate(currentVersion: currentVersion)
            }
        } catch {
            state = .failed(error: error.localizedDescription)
        }
    }

    func downloadAndInstall(downloadURL: URL, currentAppURL: URL) async {
        state = .downloading(progress: 0.1)

        do {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("DoubaoVoiceHelperUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let zipPath = tempDir.appendingPathComponent("update.zip")

            var request = URLRequest(url: downloadURL)
            request.setValue("DoubaoVoiceHelper", forHTTPHeaderField: "User-Agent")
            let (tempDownloadedURL, _) = try await URLSession.shared.download(for: request)
            try FileManager.default.moveItem(at: tempDownloadedURL, to: zipPath)

            state = .downloading(progress: 1.0)
            state = .installing

            let stagedDir = tempDir.appendingPathComponent("staged")
            try FileManager.default.createDirectory(at: stagedDir, withIntermediateDirectories: true)

            let dittoProcess = Process()
            dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            dittoProcess.arguments = ["-xk", zipPath.path, stagedDir.path]
            try dittoProcess.run()
            dittoProcess.waitUntilExit()

            guard dittoProcess.terminationStatus == 0 else {
                throw NSError(domain: "UpdateService", code: 1, userInfo: [NSLocalizedDescriptionKey: "解压更新包失败"])
            }

            let items = try FileManager.default.contentsOfDirectory(at: stagedDir, includingPropertiesForKeys: nil)
            guard let stagedApp = items.first(where: { $0.pathExtension == "app" }) else {
                throw NSError(domain: "UpdateService", code: 2, userInfo: [NSLocalizedDescriptionKey: "更新包中未包含应用程序"])
            }

            let scriptURL = tempDir.appendingPathComponent("restart_updater.sh")
            let targetPath = currentAppURL.path
            let pid = ProcessInfo.processInfo.processIdentifier

            let script = """
            #!/bin/sh
            TARGET="\(targetPath)"
            STAGED="\(stagedApp.path)"
            WAIT_PID="\(pid)"
            TEMP_DIR="\(tempDir.path)"

            while kill -0 "$WAIT_PID" 2>/dev/null; do
                sleep 0.1
            done

            rm -rf "$TARGET"
            ditto "$STAGED" "$TARGET"
            xattr -cr "$TARGET" 2>/dev/null || true
            touch "$TARGET"
            open "$TARGET"
            rm -rf "$TEMP_DIR"
            """

            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
            launcher.arguments = [scriptURL.path]
            try launcher.run()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        } catch {
            state = .failed(error: error.localizedDescription)
        }
    }
}
