#if canImport(AppKit)
import AppKit
import Foundation
import GestureCore

/// Keeps Wisp on the newest commit of the branch it was built from (`main`, unless install.sh was
/// given another): checks at launch, every 6 hours, and from the menu; installs on request.
///
/// Installing takes GitHub's prebuilt copy when the latest release was made from that exact commit.
/// Otherwise it downloads the source and builds it here with Apple's command line tools, so an
/// update never has to wait for GitHub Actions (or for Actions to be available at all).
///
/// It talks to GitHub through `gh` when installed (signed in: works for the private repository),
/// else directly (only works if the repository is public).
@MainActor
final class Updater {
    nonisolated static let repo = "ainigh/MyTouchScreen"
    nonisolated static let assetName = "GesturePointer.zip"
    /// The bundle name make-app.sh builds and zips (the installed copy may have been renamed).
    nonisolated static let builtAppName = "GesturePointer.app"

    /// The branch this copy follows (make-app.sh writes it into Info.plist).
    nonisolated static var branch: String {
        let b = Bundle.main.object(forInfoDictionaryKey: "WispBranch") as? String ?? ""
        return b.isEmpty ? "main" : b
    }

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The commit this copy was built from (make-app.sh writes it into Info.plist).
    nonisolated static var currentCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "WispCommit") as? String
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(UpdatePlan)
        case installing(String)
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { onChange?(state) }
    }
    /// Called on the main thread whenever `state` changes.
    var onChange: ((State) -> Void)?
    private var timer: Timer?
    private let work = DispatchQueue(label: "app.wisp.updater", qos: .utility)

    var isBusy: Bool {
        switch state {
        case .checking, .installing: return true
        default: return false
        }
    }

    /// One line for the menu: what this copy is.
    var versionLine: String {
        let commit = Self.currentCommit.map { " (\($0.prefix(7)))" } ?? ""
        let branch = Self.branch == "main" ? "" : " · \(Self.branch)"
        return "Wisp \(Self.currentVersion)\(commit)\(branch)"
    }

    func start() {
        // A copy built by hand (make app from a checkout without a commit, or `swift run`) isn't
        // an installed app: don't nag it about updates.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        check(userInitiated: false)
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(userInitiated: false) }
        }
    }

    func check(userInitiated: Bool) {
        if isBusy { return }
        let before = state
        state = .checking
        work.async {
            let outcome: State
            do {
                let plan = try Self.findUpdate()
                outcome = plan == .upToDate ? .upToDate : .available(plan)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A quiet background check that fails shouldn't leave an error in the menu,
                    // and an update it already found stays offered.
                    if case .failed = outcome, !userInitiated {
                        if case .available = before { self.state = before } else { self.state = .idle }
                    } else {
                        self.state = outcome
                    }
                }
            }
        }
    }

    func install() {
        guard case .available(let plan) = state else { return }
        state = .installing("Updating…")
        work.async {
            do {
                try Self.install(plan) { step in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.state = .installing(step) } }
                }
            } catch {
                Self.log("update failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.state = .failed("Update failed: \(error.localizedDescription)") }
                }
            }
        }
    }

    // MARK: - What's new

    nonisolated static func findUpdate() throws -> UpdatePlan {
        let head = try Commit.decode(api("repos/\(repo)/commits/\(branch)"))
        let release = try? Release.decode(api("repos/\(repo)/releases/latest"))
        return UpdatePlan.decide(head: head, installedCommit: currentCommit, latestRelease: release, assetName: assetName)
    }

    // MARK: - Installing

    nonisolated static func install(_ plan: UpdatePlan, step: @escaping (String) -> Void) throws {
        let fm = FileManager.default
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { throw Problem("this copy isn't an app bundle") }
        // On the app's own volume, so the swap at the end is a rename.
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? fm.removeItem(at: scratch) }

        let newApp: URL
        let commit: Commit
        switch plan {
        case .upToDate:
            return
        case let .prebuilt(head, release):
            commit = head
            step("Downloading \(release.tag)…")
            newApp = try downloadPrebuilt(release, into: scratch)
        case let .buildHere(head):
            commit = head
            newApp = try buildFromSource(head, in: scratch, step: step)
        }
        let newBundle = Bundle(url: newApp)
        let newID = newBundle?.bundleIdentifier
        guard newID != nil, newID == Bundle.main.bundleIdentifier else {
            throw Problem("the new copy isn't \(app.lastPathComponent)")
        }
        // Never swap in something that isn't the commit we meant to install, or whose bundle
        // was damaged on the way (a truncated download, a half-finished build).
        guard newBundle?.object(forInfoDictionaryKey: "WispCommit") as? String == commit.sha else {
            throw Problem("the new copy wasn't built from \(commit.short)")
        }
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        } catch {
            throw Problem("the new copy's signature doesn't check out: \(error.localizedDescription)")
        }
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        step("Restarting…")
        _ = try fm.replaceItemAt(app, withItemAt: newApp)
        log("updated to \(commit.short)")
        // Start the new copy once this one has quit.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try relaunch.run()
        DispatchQueue.main.async { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }

    nonisolated static func downloadPrebuilt(_ release: Release, into scratch: URL) throws -> URL {
        let zip = scratch.appendingPathComponent(assetName)
        // gh first (the repository is private); a gh that isn't signed in falls back to a plain download.
        if let gh = ghPath(), (try? run(gh, ["release", "download", release.tag, "--repo", repo, "--pattern", assetName,
                                            "--dir", scratch.path, "--clobber"])) != nil {
            // Downloaded by gh.
        } else if let asset = release.asset(named: assetName) {
            try download(asset.browserDownloadURL, to: zip)
        } else {
            throw Problem("the release has no \(assetName)")
        }
        let unpacked = scratch.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        return unpacked.appendingPathComponent(builtAppName)
    }

    /// Downloads the commit's source and runs scripts/make-app.sh on it (for this Mac only).
    nonisolated static func buildFromSource(_ commit: Commit, in scratch: URL, step: (String) -> Void) throws -> URL {
        guard (try? run("/usr/bin/xcode-select", ["-p"])) != nil else {
            throw Problem("building needs Apple's command line tools: run xcode-select --install in Terminal")
        }
        try checkSwift()
        step("Downloading \(commit.short)…")
        let tarball = scratch.appendingPathComponent("source.tar.gz")
        if let gh = ghPath(), (try? run(gh, ["api", "repos/\(repo)/tarball/\(commit.sha)"], to: tarball)) != nil {
            // Downloaded by gh.
        } else if let url = URL(string: "https://codeload.github.com/\(repo)/tar.gz/\(commit.sha)") {
            try download(url, to: tarball)
        }
        let src = scratch.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try run("/usr/bin/tar", ["-xzf", tarball.path, "-C", src.path, "--strip-components", "1"])

        step("Building \(commit.short) (a minute or two)…")
        log("building \(commit.short) in \(src.path)")
        let base = currentVersion.split(separator: "-").first.map(String.init) ?? "1.0"
        var env = ["VERSION": "\(base)-\(commit.short)", "COMMIT": commit.sha, "BRANCH": branch]
        // Keep signing with the same identity, if the user set one up (see README → Updates).
        if let identity = ProcessInfo.processInfo.environment["WISP_SIGN_IDENTITY"]
            ?? UserDefaults.standard.string(forKey: "signIdentity") {
            env["WISP_SIGN_IDENTITY"] = identity
        }
        try run("/bin/bash", [src.appendingPathComponent("scripts/make-app.sh").path], env: env, in: src, logOutput: true)
        return src.appendingPathComponent("build").appendingPathComponent(builtAppName)
    }

    /// The package needs Swift 5.9+. make-app.sh also uses an installed Xcode when the command
    /// line tools are older, so either being new enough will do.
    nonisolated static func checkSwift() throws {
        func output(_ developerDir: String?) -> String {
            let env = developerDir.map { ["DEVELOPER_DIR": $0] } ?? [:]
            guard let data = try? run("/bin/sh", ["-c", "/usr/bin/xcrun swift --version 2>&1"], env: env) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        let here = output(nil)
        if SwiftToolchain.isNewEnough(here) { return }
        let folders = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where name.hasPrefix("Xcode") && name.hasSuffix(".app") {
                if SwiftToolchain.isNewEnough(output("\(folder)/\(name)/Contents/Developer")) { return }
            }
        }
        let have = SwiftToolchain.version(in: here).map { "Swift \($0)" } ?? "no Swift"
        throw Problem("This Mac has \(have); building Wisp needs Swift \(SwiftToolchain.required) or newer. "
            + "Update Apple's command line tools in Software Update, or wait for GitHub to build this version.")
    }

    /// The error, plus the end of update.log when a build failed, for pasting somewhere.
    nonisolated static func report(_ problem: String) -> String {
        guard let log = try? String(contentsOf: logURL, encoding: .utf8) else { return problem }
        let tail = log.components(separatedBy: "\n").suffix(60).joined(separator: "\n")
        return problem + "\n\n--- the end of \(logURL.path) ---\n" + tail
    }

    // MARK: - GitHub

    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// GET https://api.github.com/<path>
    nonisolated static func api(_ path: String) throws -> Data {
        // gh's own error says more ("isn't signed in") than GitHub's 404 for a private repo does.
        var ghError: Error?
        if let gh = ghPath() {
            do { return try run(gh, ["api", path]) } catch { ghError = error }
        }
        guard let url = URL(string: "https://api.github.com/\(path)") else { throw Problem("bad path \(path)") }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404, let ghError { throw ghError }
        if status == 404 { throw Problem("GitHub can't see \(repo): it's private, so install gh and run gh auth login") }
        if status == 403 { throw Problem("GitHub's hourly limit: try again later, or sign in with gh auth login") }
        guard status == 200 else { throw Problem("GitHub answered \(status)") }
        return data
    }

    nonisolated static func download(_ url: URL, to file: URL) throws {
        let (data, response) = try fetch(URLRequest(url: url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Problem("download failed (GitHub answered \(status)): \(url)") }
        try data.write(to: file)
    }

    /// gh from Homebrew (apps opened from Finder don't get Terminal's PATH).
    nonisolated static func ghPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Helpers

    /// ~/Library/Logs/Wisp/update.log: what updates did, and a build's full output.
    nonisolated static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Wisp/update.log")
    }

    nonisolated static func log(_ line: String) {
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    /// Runs a program and returns its output (or writes it to `file`). Throws with the last line
    /// of its errors if it fails. `logOutput` also copies everything it printed into update.log.
    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String], env extra: [String: String] = [:],
                                in dir: URL? = nil, to file: URL? = nil, logOutput: Bool = false) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        if let dir { process.currentDirectoryURL = dir }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["GH_PROMPT_DISABLED"] = "1"
        env.merge(extra) { $1 }
        process.environment = env
        let out = Pipe(), err = Pipe()
        var outFile: FileHandle?
        if let file {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            outFile = try FileHandle(forWritingTo: file)
            process.standardOutput = outFile
        } else {
            process.standardOutput = out
        }
        defer { try? outFile?.close() }
        process.standardError = err
        try process.run()
        // Read stderr on another thread while stdout is read here, so a full pipe can't stall it.
        final class Box { var data = Data() }
        let errBox = Box()
        let errRead = DispatchGroup()
        errRead.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            errRead.leave()
        }
        let data = file == nil ? out.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        errRead.wait()
        let errData = errBox.data
        let name = (tool as NSString).lastPathComponent
        if logOutput {
            log("\(name) \(args.joined(separator: " "))\n\(String(decoding: data, as: UTF8.self))\(String(decoding: errData, as: UTF8.self))")
        }
        if process.terminationStatus != 0 {
            let lines = String(decoding: errData.isEmpty ? data : errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            let message = logOutput ? (lines.last(where: { $0.contains("error") }) ?? lines.last ?? "") : (lines.last ?? "")
            if name == "gh", message.contains("auth login") || message.contains("401") {
                throw Problem("gh isn't signed in: run gh auth login in Terminal")
            }
            let tail = message.isEmpty ? "\(name) failed (\(process.terminationStatus))" : message
            throw Problem(logOutput ? "\(tail) (details in \(logURL.path))" : tail)
        }
        return data
    }

    nonisolated static func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
        let done = DispatchSemaphore(value: 0)
        final class Box { var result: Result<(Data, URLResponse), Error> = .failure(Problem("no answer")) }
        let box = Box()
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data, let response {
                box.result = .success((data, response))
            } else {
                box.result = .failure(error ?? Problem("no answer"))
            }
            done.signal()
        }.resume()
        done.wait()
        return try box.result.get()
    }
}
#endif
