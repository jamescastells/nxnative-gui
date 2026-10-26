import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var runner = BuildRunner()

    var body: some View {
        HSplitView {
            settings
                .frame(minWidth: 380, idealWidth: 420)
            logView
                .frame(minWidth: 320)
        }
        .frame(minWidth: 800, minHeight: 520)
        .task { runner.prepare() }
        .sheet(isPresented: $runner.isHomebrewMissing) {
            HomebrewMissingView()
                .interactiveDismissDisabled()
        }
    }

    private var settings: some View {
        Form {
            Section("1. Game") {
                GamePicker(games: runner.games, selection: $runner.selectedGame)
            }

            Section("2. Files") {
                PathField(title: "Game folder (NSP + updates/DLC)", path: $runner.gameFolder, kind: .folder)
                if let warning = runner.gameFolderWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                PathField(title: "prod.keys", path: $runner.keysPath, kind: .file)
                PathField(title: "Output folder", path: $runner.outputPath, kind: .saveLocation)
            }
            .disabled(runner.selectedGame == nil)

            Section("3. Options") {
                TextField("App name", text: $runner.appName)
                Picker("Language", selection: $runner.language) {
                    ForEach(GameLanguage.allCases) { language in
                        Text("\(language.rawValue) (\(language.displayName))").tag(language)
                    }
                }
                Picker("Platform", selection: $runner.platform) {
                    ForEach(TargetPlatform.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Prepare Xcode project only", isOn: $runner.prepareXcode)
                Toggle("Show FPS overlay", isOn: $runner.showFPS)
            }
            .disabled(runner.selectedGame == nil)

            Section {
                HStack {
                    if runner.isRunning {
                        Button("Cancel", role: .cancel) { runner.cancel() }
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Build") { runner.start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!runner.canStart)
                    }
                    Spacer()
                    if let status = runner.exitStatus {
                        Label(status == 0 ? "Succeeded" : "Failed",
                              systemImage: status == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(status == 0 ? .green : .red)
                    }
                }
                Text("The first build can take 30–60 minutes. Required tools (dotnet, xcodegen, zstd, spirv-cross, glslang and the Python modules lz4, capstone, fonttools, zstd, and Xcode's Metal Toolchain) are installed automatically when the app opens; Homebrew must already be installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if runner.entries.isEmpty {
                    Text("Progress will appear here.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(runner.entries) { entry in
                            LogEntryRow(entry: entry,
                                        isCurrent: runner.isRunning && entry.id == runner.entries.last?.id)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                Color.clear.frame(height: 1).id("bottom")
            }
            .onChange(of: runner.entries.count) {
                proxy.scrollTo("bottom")
            }
        }
        .background(.background.secondary)
    }
}

/// A button showing the chosen game. It opens a popover with a search field and the matching games.
private struct GamePicker: View {
    let games: [SupportedGame]
    @Binding var selection: SupportedGame?
    @State private var isPresented = false

    var body: some View {
        LabeledContent("Supported game") {
            Button {
                isPresented = true
            } label: {
                HStack {
                    Text(selection?.name ?? (games.isEmpty ? "Loading games…" : "Select a game…"))
                        .foregroundStyle(selection == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(games.isEmpty)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                GameSearchList(games: games, selection: selection) { game in
                    selection = game
                    isPresented = false
                }
            }
        }
    }
}

/// The popover's content: a search field above the games that match it.
private struct GameSearchList: View {
    let games: [SupportedGame]
    let selection: SupportedGame?
    let onSelect: (SupportedGame) -> Void

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    /// Games matching every word typed, ignoring case and accents (so "pokemon" finds "Pokémon").
    /// The title ID is searchable too.
    private var matches: [SupportedGame] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return games }
        return games.filter { game in
            words.allSatisfy { word in
                [game.name, game.titleID].contains {
                    $0.range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search games", text: $query)
                .textFieldStyle(.roundedBorder)
                // The popover inherits the Form's trailing alignment, so set it explicitly.
                .multilineTextAlignment(.leading)
                .focused($isSearchFocused)
                // Return picks the first match, so you can type a few letters and confirm.
                .onSubmit { if let first = matches.first { onSelect(first) } }

            if matches.isEmpty {
                Text("No matching games")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(matches) { game in
                    Button {
                        onSelect(game)
                    } label: {
                        HStack {
                            Text(game.name)
                            Spacer()
                            if game == selection {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .padding(12)
        .frame(width: 380, height: 360)
        .onAppear { isSearchFocused = true }
    }
}

/// One progress line: an icon (a spinner while it's the step in progress) and the message.
private struct LogEntryRow: View {
    let entry: LogEntry
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon
                .frame(width: 16)
            Text(entry.text)
                .font(entry.kind == .detail ? .caption : .body)
                .foregroundStyle(color)
                // Let long lines wrap onto extra lines and grow the row, instead of overlapping the next one.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var icon: some View {
        if isCurrent && (entry.kind == .info || entry.kind == .detail) {
            ProgressView().controlSize(.mini)
        } else {
            switch entry.kind {
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failure: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .info: Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary)
            // Color.clear stretches to any height it's offered, which breaks the row's height; pin it.
            case .detail: Color.clear.frame(width: 1, height: 1)
            }
        }
    }

    private var color: Color {
        switch entry.kind {
        case .error, .failure: .red
        case .detail: .secondary
        case .info, .success: .primary
        }
    }
}

/// A read-only path display with a Browse button that is the only way to set the path.
private struct PathField: View {
    enum Kind { case file, folder, saveLocation }

    let title: String
    @Binding var path: String
    let kind: Kind
    @State private var isImporting = false

    var body: some View {
        HStack {
            LabeledContent(title) {
                Text(path.isEmpty ? "Not selected" : path)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            }
            Button("Browse…") { isImporting = true }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: kind == .file ? [.data] : [.folder]
        ) { result in
            if case .success(let url) = result {
                path = url.path
            }
        }
    }
}

/// Blocking error shown at startup when Homebrew is needed but not installed. Close quits the app.
private struct HomebrewMissingView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("Homebrew Required")
                .font(.headline)
            VStack(spacing: 4) {
                Text("Homebrew is required to install these tools but wasn't found.")
                HStack(spacing: 0) {
                    Text("Install it from ")
                    Link("https://brew.sh", destination: URL(string: "https://brew.sh")!)
                    Text(", then reopen the app.")
                }
            }
            .multilineTextAlignment(.center)
            // terminate(_:) can be swallowed while a sheet is up; nothing needs saving here, so exit directly.
            Button("Close") { exit(0) }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(minWidth: 380)
    }
}

#Preview {
    ContentView()
}
