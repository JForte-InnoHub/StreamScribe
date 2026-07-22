import Foundation

/// Provisions the bgutil PO-token provider for yt-dlp and supplies the
/// arguments/environment needed to activate it on every yt-dlp invocation.
///
/// Design (verified against Brainicism/bgutil-ytdlp-pot-provider 1.3.1, 2026-07-17):
/// - Plugin: release asset `bgutil-ytdlp-pot-provider.zip` dropped into a plugin
///   dir passed via `--plugin-dirs`. yt-dlp loads the zip in place (verified:
///   "Plugin directories: .../bgutil-ytdlp-pot-provider.zip/yt_dlp_plugins").
/// - Provider: SCRIPT mode via Deno (`bgutil:script-deno`, plugin preference 20 —
///   preferred over script-node's 10). No daemon, no Node runtime, no transpile:
///   Deno runs `server/src/generate_once.ts` directly. Requires Deno >= 2.0.0.
/// - The server source tree (repo tag matching the plugin version) must exist on
///   disk with `node_modules` populated via `deno install --allow-scripts=npm:canvas --frozen`.
/// - Plugin and script MUST be the same major version (plugin hard-rejects on
///   mismatch), so both are pinned to `pinnedVersion` and provisioned together.
/// - The script caches tokens in `$XDG_CACHE_HOME/bgutil-ytdlp-pot-provider` or
///   `~/.cache/bgutil-ytdlp-pot-provider`. The plugin only grants Deno
///   `--allow-write` on that exact dir, so if `~/.cache` itself is missing
///   (common on macOS) the script's recursive mkdir fails. We pre-create it.
/// - Passing `--js-runtimes deno:<path>` additionally enables yt-dlp's built-in
///   `deno` JS-challenge provider (nsig/player challenges) for free.
///
/// Distribution policy: tools fetch directly from GitHub (R2 mirror is for
/// HF-hosted models only).
final class PotProviderManager: @unchecked Sendable {

    static let shared = PotProviderManager()

    /// Plugin zip and server tree are pinned together; bump both by changing this.
    static let pinnedVersion = "1.3.1"

    // MARK: - Paths

    private let fileManager = FileManager.default

    private var appSupportDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("StreamScribe", isDirectory: true)
    }

    /// Directory handed to yt-dlp via `--plugin-dirs`; contains the plugin zip.
    var pluginDirectory: URL {
        appSupportDirectory.appendingPathComponent("yt-dlp-plugins", isDirectory: true)
    }

    private var pluginZipURL: URL {
        pluginDirectory.appendingPathComponent("bgutil-ytdlp-pot-provider.zip")
    }

    private var potRootDirectory: URL {
        appSupportDirectory.appendingPathComponent("bgutil-pot", isDirectory: true)
    }

    private var versionDirectory: URL {
        potRootDirectory.appendingPathComponent(Self.pinnedVersion, isDirectory: true)
    }

    /// Passed to yt-dlp as `youtubepot-bgutilscript:server_home=...`.
    var serverDirectory: URL {
        versionDirectory.appendingPathComponent("server", isDirectory: true)
    }

    private var provisionedMarkerURL: URL {
        versionDirectory.appendingPathComponent(".provisioned")
    }

    /// Token cache dir the generation script uses; resolved the same way the
    /// script does (XDG_CACHE_HOME, else HOME/.cache).
    private var scriptCacheDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_CACHE_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("bgutil-ytdlp-pot-provider", isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("bgutil-ytdlp-pot-provider", isDirectory: true)
    }

    // MARK: - Remote sources (GitHub direct, pinned)

    private var pluginZipRemoteURL: URL {
        URL(string: "https://github.com/Brainicism/bgutil-ytdlp-pot-provider/releases/download/\(Self.pinnedVersion)/bgutil-ytdlp-pot-provider.zip")!
    }

    private var sourceTarballRemoteURL: URL {
        URL(string: "https://github.com/Brainicism/bgutil-ytdlp-pot-provider/archive/refs/tags/\(Self.pinnedVersion).tar.gz")!
    }

    // MARK: - State

    /// True when everything needed for `bgutil:script-deno` is on disk.
    var isProvisioned: Bool {
        fileManager.fileExists(atPath: pluginZipURL.path)
            && fileManager.fileExists(atPath: serverDirectory.appendingPathComponent("src/generate_once.ts").path)
            && fileManager.fileExists(atPath: serverDirectory.appendingPathComponent("node_modules", isDirectory: true).path)
            && fileManager.fileExists(atPath: provisionedMarkerURL.path)
    }

    private let provisioningLock = NSLock()
    private var provisioningTask: Task<Void, Error>?

    // MARK: - yt-dlp integration

    /// Arguments to append to EVERY yt-dlp invocation (probe, VOD, live, cache
    /// download). Returns [] until provisioning has completed, so call sites can
    /// append unconditionally.
    ///
    /// Note: `--extractor-args` accumulates per extractor key, so a separate
    /// `--extractor-args youtube:...` (e.g. the upcoming player_client rotation
    /// setting) can coexist with the `youtubepot-bgutilscript:` one below.
    func ytDlpArguments(denoPath: String) -> [String] {
        guard isProvisioned else { return [] }
        return [
            "--plugin-dirs", pluginDirectory.path,
            "--js-runtimes", "deno:\(denoPath)",
            "--extractor-args", "youtubepot-bgutilscript:server_home=\(serverDirectory.path)",
        ]
    }

    /// Environment additions for yt-dlp invocations. The plugin spawns Deno with
    /// the yt-dlp process environment, so a corporate TLS-interception CA (fleet
    /// behind Netskope) must be exported here for the script's calls to Google.
    /// Pass the app's existing extra-CA-cert setting; nil/empty is a no-op.
    func ytDlpEnvironmentAdditions(extraCACertPath: String?) -> [String: String] {
        var env: [String: String] = [
            "DENO_NO_UPDATE_CHECK": "1",
        ]
        if let cert = extraCACertPath, !cert.isEmpty {
            env["DENO_CERT"] = cert
        }
        return env
    }

    // MARK: - Provisioning

    /// Idempotent; concurrent callers share one in-flight task. `denoPath` is the
    /// bundled Deno executable (must be >= 2.0.0). Network: github.com,
    /// codeload/release-assets (tarball + plugin zip), registry.npmjs.org and
    /// GitHub release assets (canvas prebuilt) during `deno install`.
    func provisionIfNeeded(denoPath: String,
                           extraCACertPath: String? = nil,
                           progress: (@Sendable (String) -> Void)? = nil) async throws {
        if isProvisioned {
            try ensureScriptCacheDirectory()
            return
        }

        provisioningLock.lock()
        if let existing = provisioningTask {
            provisioningLock.unlock()
            try await existing.value
            return
        }
        let task = Task {
            try await self.performProvisioning(denoPath: denoPath,
                                               extraCACertPath: extraCACertPath,
                                               progress: progress)
        }
        provisioningTask = task
        provisioningLock.unlock()

        defer {
            provisioningLock.lock()
            provisioningTask = nil
            provisioningLock.unlock()
        }
        try await task.value
    }

    private func performProvisioning(denoPath: String,
                                     extraCACertPath: String?,
                                     progress: (@Sendable (String) -> Void)?) async throws {
        progress?("Preparing PO-token provider \(Self.pinnedVersion)…")
        try fileManager.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
        try ensureScriptCacheDirectory()

        // 1. Plugin zip → yt-dlp-plugins/ (loaded by yt-dlp as a zip in place).
        if !fileManager.fileExists(atPath: pluginZipURL.path) {
            progress?("Downloading provider plugin…")
            let tempZip = try await download(pluginZipRemoteURL)
            try replaceItem(at: pluginZipURL, with: tempZip)
            print("[PotProvider] Plugin zip installed at \(pluginZipURL.path)")
        }

        // 2. Server source tree (same tag as the plugin — major versions must match).
        let generateOnce = serverDirectory.appendingPathComponent("src/generate_once.ts")
        if !fileManager.fileExists(atPath: generateOnce.path) {
            progress?("Downloading provider script…")
            let tarball = try await download(sourceTarballRemoteURL)
            try extractServerTree(from: tarball)
            print("[PotProvider] Server tree extracted to \(serverDirectory.path)")
        }

        // 3. Dependencies via bundled Deno (canvas ships a prebuilt binary; its
        //    install script must be allowed explicitly).
        let nodeModules = serverDirectory.appendingPathComponent("node_modules", isDirectory: true)
        let canvasDir = nodeModules.appendingPathComponent("canvas", isDirectory: true)
        if !fileManager.fileExists(atPath: canvasDir.path) {
            progress?("Installing provider dependencies…")
            try runProcess(executable: denoPath,
                           arguments: ["install", "--allow-scripts=npm:canvas", "--frozen"],
                           currentDirectory: serverDirectory,
                           extraEnvironment: denoEnvironment(extraCACertPath: extraCACertPath),
                           label: "deno install")
        }

        // 4. Self-test: exact invocation the plugin performs for availability.
        progress?("Verifying provider…")
        let reportedVersion = try selfTestVersion(denoPath: denoPath, extraCACertPath: extraCACertPath)
        guard reportedVersion == Self.pinnedVersion else {
            throw PotProviderError.versionMismatch(expected: Self.pinnedVersion, got: reportedVersion)
        }

        try Data().write(to: provisionedMarkerURL)
        removeStaleVersions()
        print("[PotProvider] Provisioned \(Self.pinnedVersion) (script-deno) OK")
        progress?("PO-token provider ready.")
    }

    /// Mirrors BgUtilScriptDenoPTP: run src/generate_once.ts --version with the
    /// same permission flags and env the plugin uses; expects the bare version.
    private func selfTestVersion(denoPath: String, extraCACertPath: String?) throws -> String {
        let nodeModules = serverDirectory.appendingPathComponent("node_modules", isDirectory: true).path
        let cache = scriptCacheDirectory.path
        let output = try runProcess(
            executable: denoPath,
            arguments: [
                "run", "--allow-env", "--allow-net",
                "--allow-ffi=\(nodeModules)",
                "--allow-write=\(cache)",
                "--allow-read=\(cache),\(nodeModules)",
                serverDirectory.appendingPathComponent("src/generate_once.ts").path,
                "--version",
            ],
            currentDirectory: serverDirectory,
            extraEnvironment: denoEnvironment(extraCACertPath: extraCACertPath),
            label: "provider self-test")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func denoEnvironment(extraCACertPath: String?) -> [String: String] {
        var env: [String: String] = [
            "DENO_NO_PROMPT": "1",
            "DENO_NO_UPDATE_CHECK": "1",
            "FORCE_COLOR": "false",
        ]
        if let cert = extraCACertPath, !cert.isEmpty {
            env["DENO_CERT"] = cert
        }
        return env
    }

    /// The generation script mkdirs its cache dir recursively, but the plugin only
    /// grants --allow-write on the final dir — if ~/.cache is absent the mkdir is
    /// denied. Creating it here (unsandboxed Swift) sidesteps that.
    private func ensureScriptCacheDirectory() throws {
        try fileManager.createDirectory(at: scriptCacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Helpers

    private func download(_ url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PotProviderError.downloadFailed(url: url, statusCode: code)
        }
        return tempURL
    }

    private func replaceItem(at destination: URL, with source: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    /// Extracts only the repo's server/ subtree into versionDirectory/server.
    private func extractServerTree(from tarball: URL) throws {
        let memberPrefix = "bgutil-ytdlp-pot-provider-\(Self.pinnedVersion)/server"
        _ = try runProcess(
            executable: "/usr/bin/tar",
            arguments: ["xzf", tarball.path,
                        "-C", versionDirectory.path,
                        "--strip-components=1",
                        memberPrefix],
            currentDirectory: versionDirectory,
            extraEnvironment: [:],
            label: "tar extract")
        try? fileManager.removeItem(at: tarball)
    }

    /// Keep only the pinned version under bgutil-pot/ once it is provisioned.
    private func removeStaleVersions() {
        guard let entries = try? fileManager.contentsOfDirectory(at: potRootDirectory,
                                                                 includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent != Self.pinnedVersion {
            try? fileManager.removeItem(at: entry)
            print("[PotProvider] Removed stale version dir \(entry.lastPathComponent)")
        }
    }

    @discardableResult
    private func runProcess(executable: String,
                            arguments: [String],
                            currentDirectory: URL,
                            extraEnvironment: [String: String],
                            label: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var env = ProcessInfo.processInfo.environment
        for (key, value) in extraEnvironment { env[key] = value }
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outText = String(data: outData, encoding: .utf8) ?? ""
        let errText = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            print("[PotProvider] \(label) failed (\(process.terminationStatus)):\n\(outText)\n\(errText)")
            throw PotProviderError.processFailed(label: label,
                                                 status: process.terminationStatus,
                                                 output: errText.isEmpty ? outText : errText)
        }
        return outText
    }
}

enum PotProviderError: LocalizedError {
    case downloadFailed(url: URL, statusCode: Int)
    case processFailed(label: String, status: Int32, output: String)
    case versionMismatch(expected: String, got: String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let url, let statusCode):
            return "PO-token provider download failed (\(statusCode)): \(url.absoluteString)"
        case .processFailed(let label, let status, let output):
            return "PO-token provider step '\(label)' failed with status \(status): \(output.prefix(500))"
        case .versionMismatch(let expected, let got):
            return "PO-token provider self-test returned version '\(got)', expected '\(expected)'."
        }
    }
}
