import Foundation
import Observation

enum TargetPlatform: String, CaseIterable, Identifiable {
    case ipa = "IPA (iPhone / iPad)"
    case macApp = "Mac App"

    var id: String { rawValue }
}

enum GameLanguage: String, CaseIterable, Identifiable {
    case enUS = "en-US"
    case enGB = "en-GB"
    case ja
    case fr
    case de
    case es419 = "es-419"
    case es
    case it
    case nl
    case frCA = "fr-CA"
    case pt
    case ru
    case ko
    case zhHant = "zh-Hant"
    case zhHans = "zh-Hans"
    case ptBR = "pt-BR"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .enUS: "American English"
        case .enGB: "British English"
        case .ja: "Japanese"
        case .fr: "French"
        case .de: "German"
        case .es419: "Latin American Spanish"
        case .es: "Spanish"
        case .it: "Italian"
        case .nl: "Dutch"
        case .frCA: "Canadian French"
        case .pt: "Portuguese"
        case .ru: "Russian"
        case .ko: "Korean"
        case .zhHant: "Traditional Chinese"
        case .zhHans: "Simplified Chinese"
        case .ptBR: "Brazilian Portuguese"
        }
    }
}

/// A missing requirement that stops the app until the user fixes it and reopens it.
enum BlockingError: String, Identifiable {
    case xcodeMissing
    case homebrewMissing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xcodeMissing: "Xcode Required"
        case .homebrewMissing: "Homebrew Required"
        }
    }

    var summary: String {
        switch self {
        case .xcodeMissing:
            "Xcode is required to convert games: it provides the Metal shader compiler and the build tools."
        case .homebrewMissing:
            "Homebrew is required to install these tools but wasn't found."
        }
    }

    /// Markdown, so the link is clickable.
    var instructions: String {
        switch self {
        case .xcodeMissing:
            "Install it from the [Mac App Store](https://apps.apple.com/app/xcode/id497799835), open it once to finish setup, then reopen the app."
        case .homebrewMissing:
            "Install it from [https://brew.sh](https://brew.sh), then reopen the app."
        }
    }
}

/// One line of build output, cleaned up for display.
struct LogEntry: Identifiable {
    enum Kind {
        case info       // plain progress message
        case success    // a finished step
        case failure    // a failed step or run
        case error      // the script's own error message
        case detail     // supporting output (indented lines, tracebacks, git output)
    }

    let id: Int
    let text: String
    let kind: Kind

    init(id: Int, line: String) {
        self.id = id
        var text = line
        // Drop the script's "[20:13:34] " timestamp prefix.
        if let stamp = text.firstMatch(of: /^\[\d{2}:\d{2}:\d{2}\]\s/) {
            text.removeSubrange(stamp.range)
        }

        if text.hasPrefix("[RED] ") {
            self.text = String(text.dropFirst(6))
            kind = .error
        } else if text.hasPrefix("✓ ") {
            self.text = String(text.dropFirst(2))
            kind = .success
        } else if text.hasPrefix("✗ ") {
            self.text = String(text.dropFirst(2))
            kind = .failure
        } else if text.hasPrefix("Exited with status") {
            self.text = text
            kind = .failure
        } else if text == "Done." || text == "Ready." {
            self.text = text
            kind = .success
        } else if text.first?.isWhitespace == true || text.hasPrefix("Traceback") || text.hasPrefix("From ")
                    || text.hasPrefix("HEAD is now at") {
            self.text = text.trimmingCharacters(in: .whitespaces)
            kind = .detail
        } else {
            self.text = text
            kind = .info
        }
    }
}

/// A game with a profile in nxnative's `dm/games` folder.
struct SupportedGame: Identifiable, Hashable {
    let name: String
    let titleID: String

    var id: String { titleID }

    /// The game's name as a file-name-safe app name (`:` and `/` are awkward in file names).
    var defaultAppName: String {
        name.replacingOccurrences(of: ":", with: " -")
            .replacingOccurrences(of: "/", with: "-")
    }
}

/// Downloads nxnative, then runs `scripts/build_ipa_from_nsp.py` from it and streams the output.
@MainActor
@Observable
final class BuildRunner {
    private static let remoteURL = "https://github.com/seedds/nxnative.git"

    // Inputs
    private(set) var games: [SupportedGame] = []
    /// Choosing a game names the output after it (the user can still edit the name) and
    /// clears the game folder, which was picked for the previous game.
    var selectedGame: SupportedGame? {
        didSet {
            guard selectedGame != oldValue else { return }
            gameFolder = ""
            if let game = selectedGame { appName = game.defaultAppName }
        }
    }
    var gameFolder = ""
    var keysPath = ""
    var outputPath = ""
    var appName = ""
    var language: GameLanguage = .enUS
    var platform: TargetPlatform = .ipa
    var prepareXcode = false
    var showFPS = false

    // State
    private(set) var entries: [LogEntry] = []
    private(set) var isRunning = false
    private(set) var exitStatus: Int32?
    /// Set when tools need installing but Homebrew isn't available; the UI shows a blocking error.
    var blockingError: BlockingError?

    private var process: Process?
    private var isCancelled = false

    /// Where the nxnative checkout is stored: ~/Library/Application Support/<app>/nxnative
    private var repoURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "nxnative-gui", isDirectory: true)
            .appendingPathComponent("nxnative", isDirectory: true)
    }

    var canStart: Bool {
        !isRunning && selectedGame != nil && !gameFolder.isEmpty && !keysPath.isEmpty
    }

    /// The command line arguments passed to python3, built from the current inputs.
    private var buildArguments: [String] {
        var args = [
            repoURL.appendingPathComponent("scripts/build_ipa_from_nsp.py").path,
            gameFolder,
            "-k", keysPath
        ]
        // The script wants the output file itself (<name>.app, or <name>.ipa), not a folder.
        if !outputPath.isEmpty {
            let fileName = (appName.isEmpty ? selectedGame?.defaultAppName : appName)?
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: " -")
            if let fileName, !fileName.isEmpty {
                let ext = platform == .macApp ? "app" : "ipa"
                args += ["-o", URL(fileURLWithPath: outputPath).appendingPathComponent("\(fileName).\(ext)").path]
            }
        }
        if !appName.isEmpty { args += ["--app-name", appName] }
        args += ["--language", language.rawValue]
        if platform == .macApp { args += ["--platform", "mac-app"] }
        if prepareXcode { args.append("--prepare-xcode") }
        if showFPS { args.append("--show-fps") }
        return args
    }

    func start() {
        guard canStart else { return }
        entries = []
        exitStatus = nil
        isCancelled = false
        isRunning = true

        Task {
            let status = await run()
            exitStatus = status
            isRunning = false
            process = nil
            append(status == 0 ? "\nDone.\n" : "\nExited with status \(status).\n")
        }
    }

    func cancel() {
        isCancelled = true
        process?.terminate()
    }

    /// Checks the required tools when the app opens, installing any that are missing.
    func prepare() {
        guard !isRunning else { return }
        entries = []
        exitStatus = nil
        isCancelled = false
        isRunning = true

        Task {
            guard requireXcode() else {
                isRunning = false
                exitStatus = 1
                return
            }
            // Download the repo first: it holds the list of supported games.
            if await syncRepo() != 0 {
                isRunning = false
                exitStatus = 1
                return
            }
            append("\n")
            let ready = await ensureDependencies()
            isRunning = false
            process = nil
            if ready {
                append("Ready.\n")
            } else {
                exitStatus = 1
            }
        }
    }

    /// Shows the blocking "Xcode required" error and returns false if full Xcode isn't installed.
    private func requireXcode() -> Bool {
        guard isXcodeInstalled() else {
            blockingError = .xcodeMissing
            return false
        }
        return true
    }

    /// True when the active developer directory is a full Xcode (not just the Command Line Tools,
    /// which have no Metal compiler or `xcodebuild`). Uses `xcode-select`, which never pops up
    /// the "install developer tools" dialog the way `xcodebuild` or `xcrun` can.
    private func isXcodeInstalled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return false }
        return !path.hasSuffix("CommandLineTools")
            && FileManager.default.isExecutableFile(atPath: "\(path)/usr/bin/xcodebuild")
    }

    /// Updates nxnative, then runs the build. Returns the final exit status.
    private func run() async -> Int32 {
        let repo = repoURL
        guard requireXcode() else { return 1 }
        let status = await syncRepo()
        guard status == 0 else { return status }

        append("\n")
        guard await ensureDependencies() else { return 1 }
        append("\n")
        return await runCommand(["python3"] + buildArguments, in: repo)
    }

    /// Clones nxnative on first use, otherwise pulls updates, then refreshes the supported games list.
    private func syncRepo() async -> Int32 {
        let repo = repoURL
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: repo.appendingPathComponent(".git").path) {
            append("Updating nxnative…\n")
            // The copy belongs to this app, so match the remote exactly rather than `git pull`, which
            // can fail on a shallow clone or rewritten history and leave the games list stale.
            var status = await runCommand(["git", "fetch", "--depth", "1", "origin", "HEAD"], in: repo)
            if status == 0 {
                status = await runCommand(["git", "reset", "--hard", "FETCH_HEAD"], in: repo)
            }
            // An update failure (e.g. offline) shouldn't block building with the existing copy.
            if status != 0 && !isCancelled { append("Update failed; using existing copy.\n") }
        } else {
            append("Downloading nxnative…\n")
            do {
                try fileManager.createDirectory(at: repo.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
            } catch {
                append("Could not create download folder: \(error.localizedDescription)\n")
                return 1
            }
            // Remove any partial clone left by an interrupted download.
            try? fileManager.removeItem(at: repo)
            let status = await runCommand(["git", "clone", "--depth", "1", Self.remoteURL, repo.path],
                                          in: repo.deletingLastPathComponent())
            guard status == 0 else { return status }
        }
        if isCancelled { return 130 }

        loadGames()
        return 0
    }

    /// Reads the supported games from the table in `dm/games/README.md`, one row per game profile:
    /// `| [Name](<titleID>/README.md) | `<titleID>` | …`
    private func loadGames() {
        let readme = repoURL.appendingPathComponent("dm/games/README.md")
        guard let text = try? String(contentsOf: readme, encoding: .utf8) else { return }

        var loaded: [SupportedGame] = []
        for line in text.split(separator: "\n") {
            guard let match = line.firstMatch(of: /^\| \[(.+?)\]\([^)]*\) \| `([0-9A-Fa-f]{16})`/) else { continue }
            loaded.append(SupportedGame(name: String(match.1), titleID: String(match.2).uppercased()))
        }
        games = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Keep the selection valid if the list changed underneath it.
        if let selected = selectedGame, !games.contains(selected) { selectedGame = nil }
    }

    /// Game file types the nxnative script can handle.
    private static let gameFileExtensions: Set<String> = ["nsp", "xci", "nsz", "xcz"]

    /// A warning when the chosen folder has no game file for the selected game, or nil if it looks right.
    var gameFolderWarning: String? {
        guard let game = selectedGame, !gameFolder.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(atPath: gameFolder) else { return nil }
        let gameFiles = files.filter {
            Self.gameFileExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }
        guard !gameFiles.isEmpty else { return "No .nsp, .xci, .nsz or .xcz files found in this folder." }
        let hasGame = gameFiles.contains { $0.uppercased().contains(game.titleID) }
        return hasGame ? nil : "No game file in this folder has the title ID of \(game.name) (\(game.titleID))."
    }

    /// The environment for child processes. GUI apps don't inherit the shell PATH, so add the
    /// locations where Homebrew and the .NET installer put xcodegen, zstd, spirv-cross, glslang and dotnet.
    private var childEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extraPaths = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "/usr/local/share/dotnet", "\(home)/.dotnet"
        ]
        let basePath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = (extraPaths + [basePath]).joined(separator: ":")
        environment["PYTHONUNBUFFERED"] = "1"
        // Apps built by `dotnet` (like nx_extract) look for the runtime in DOTNET_ROOT. Homebrew's
        // dotnet keeps it under its own prefix rather than the default /usr/local/share/dotnet.
        if environment["DOTNET_ROOT"] == nil {
            let candidates = [
                "/opt/homebrew/opt/dotnet/libexec", "/usr/local/opt/dotnet/libexec",
                "/usr/local/share/dotnet", "\(home)/.dotnet"
            ]
            if let root = candidates.first(where: { FileManager.default.isExecutableFile(atPath: "\($0)/dotnet") }) {
                environment["DOTNET_ROOT"] = root
            }
        }
        return environment
    }

    /// Missing requirements, as the package names to install.
    private struct MissingDependencies {
        var brewPackages: [String] = []
        var pipPackages: [String] = []
        /// Xcode's Metal Toolchain, a separate download needed to compile the game's shaders.
        var metalToolchain = false
        var isEmpty: Bool { brewPackages.isEmpty && pipPackages.isEmpty && !metalToolchain }
    }

    private var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Makes sure everything nxnative needs is installed, installing what's missing.
    private func ensureDependencies() async -> Bool {
        append("Checking requirements…\n")
        var missing = findMissingDependencies()
        guard !missing.isEmpty else {
            append("All requirements are installed.\n")
            return true
        }

        if !missing.brewPackages.isEmpty {
            append("Missing tools: \(missing.brewPackages.joined(separator: ", "))\n")
        }
        if missing.metalToolchain {
            append("Missing: Xcode Metal Toolchain\n")
        }
        if !missing.pipPackages.isEmpty {
            append("Missing Python modules: \(missing.pipPackages.joined(separator: ", "))\n")
        }

        if !missing.brewPackages.isEmpty {
            guard let brew = brewPath else {
                blockingError = .homebrewMissing
                return false
            }
            append("\nInstalling tools with Homebrew (this can take a few minutes)…\n")
            // `dotnet` is the formula for the SDK; the `dotnet-sdk` cask needs an admin password.
            let status = await runCommand([brew, "install"] + missing.brewPackages,
                                          in: URL(fileURLWithPath: NSHomeDirectory()))
            if isCancelled { return false }
            if status != 0 { append("Homebrew install failed.\n") }
        }

        if !missing.pipPackages.isEmpty {
            append("\nInstalling Python modules…\n")
            let status = await runCommand(["python3", "-m", "pip", "install", "--user"] + missing.pipPackages,
                                          in: URL(fileURLWithPath: NSHomeDirectory()))
            if isCancelled { return false }
            if status != 0 { append("pip install failed.\n") }
        }

        if missing.metalToolchain {
            append("\nDownloading the Metal Toolchain (a large download, this can take a while)…\n")
            let status = await runCommand(["xcodebuild", "-downloadComponent", "MetalToolchain"],
                                          in: URL(fileURLWithPath: NSHomeDirectory()))
            if isCancelled { return false }
            if status != 0 { append("Metal Toolchain download failed.\n") }
        }

        missing = findMissingDependencies()
        guard missing.isEmpty else {
            let names = missing.brewPackages + missing.pipPackages + (missing.metalToolchain ? ["Metal Toolchain"] : [])
            append("\nStill missing: \(names.joined(separator: ", ")). "
                   + "Install them manually, then press Build.\n")
            return false
        }
        append("\nAll requirements installed.\n")
        return true
    }

    /// Checks which required tools and Python modules are not installed.
    private func findMissingDependencies() -> MissingDependencies {
        let environment = childEnvironment
        let searchPaths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        func hasExecutable(_ name: String) -> Bool {
            searchPaths.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
        }
        func hasPythonModule(_ name: String) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-c", "import \(name)"]
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }

        // Each entry: display name, Homebrew/pip package, and whether it's present.
        let tools: [(name: String, brew: String, found: Bool)] = [
            ("dotnet", "dotnet", hasExecutable("dotnet")),
            ("xcodegen", "xcodegen", hasExecutable("xcodegen")),
            ("zstd", "zstd", hasExecutable("zstd")),
            ("spirv-cross", "spirv-cross", hasExecutable("spirv-cross")),
            ("glslang", "glslang", hasExecutable("glslangValidator") || hasExecutable("glslang"))
        ]
        let modules: [(name: String, pip: String, found: Bool)] = [
            ("lz4", "lz4", hasPythonModule("lz4.block")),
            ("capstone", "capstone", hasPythonModule("capstone")),
            ("fontTools", "fonttools", hasPythonModule("fontTools")),
            // zstd is built into Python 3.14+; older versions need the backport.
            ("zstd", "backports.zstd", hasPythonModule("compression.zstd") || hasPythonModule("backports.zstd"))
        ]

        // `xcrun metal` fails when the Metal Toolchain component isn't installed.
        let metal = Process()
        metal.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        metal.arguments = ["-sdk", "macosx", "metal", "--version"]
        metal.environment = environment
        metal.standardOutput = FileHandle.nullDevice
        metal.standardError = FileHandle.nullDevice
        var hasMetal = false
        if (try? metal.run()) != nil {
            metal.waitUntilExit()
            hasMetal = metal.terminationStatus == 0
        }

        return MissingDependencies(
            brewPackages: tools.filter { !$0.found }.map(\.brew),
            pipPackages: modules.filter { !$0.found }.map(\.pip),
            metalToolchain: !hasMetal
        )
    }

    /// Runs a command via `env`, streaming its output to the log, and returns its exit status.
    private func runCommand(_ command: [String], in directory: URL) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = directory

        process.environment = childEnvironment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        append("$ " + command.joined(separator: " ") + "\n")

        do {
            try process.run()
        } catch {
            append("Failed to launch: \(error.localizedDescription)\n")
            return 127
        }
        self.process = process

        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                append(line + "\n")
            }
        } catch {
            append("Read error: \(error.localizedDescription)\n")
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Turns raw output (one or more lines) into display entries. Blank lines are dropped and the
    /// command echoes (`$ git …`) are hidden, since they're terminal detail rather than progress.
    private func append(_ text: String) {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard !line.hasPrefix("$ "), !line.allSatisfy(\.isWhitespace) else { continue }
            entries.append(LogEntry(id: entries.count, line: line))
        }
    }
}
