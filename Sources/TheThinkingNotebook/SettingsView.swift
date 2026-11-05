import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AISettings()
                .tabItem { Label("AI", systemImage: "sparkles") }
            NotesSettings()
                .tabItem { Label("Notes", systemImage: "folder") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .frame(width: 580)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(Prefs.sendKey) private var sendKey = "return"
    @AppStorage(Prefs.seesWholeNote) private var seesWholeNote = false
    @AppStorage(Prefs.customInstructions) private var customInstructions = ""

    var body: some View {
        Form {
            Section {
                Picker("Send a highlight with", selection: $sendKey) {
                    Text("Return").tag("return")
                    Text("⌘ Return").tag("commandReturn")
                }
                .pickerStyle(.segmented)
                Text(sendKey == "return"
                     ? "Return with nothing highlighted still starts a new line."
                     : "Plain Return always types normally; ⌘Return sends the highlight.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("What the AI sees") {
                Picker("What the AI sees", selection: $seesWholeNote) {
                    Text("Only the text I highlight").tag(false)
                    Text("The highlight, plus the rest of the note as background").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(seesWholeNote
                     ? "The whole note is sent with each highlight, so the AI can catch contradictions with other parts. Notes still go only beside what you highlighted."
                     : "Nothing you haven't highlighted leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Custom instructions") {
                TextEditor(text: $customInstructions)
                    .font(.body)
                    .frame(height: 90)
                    .overlay(alignment: .topLeading) {
                        if customInstructions.isEmpty {
                            Text("e.g. Be blunt. Quiz me instead of explaining. I'm studying for an algorithms exam.")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                Text("Added to every margin note and reply. The AI still never writes on your page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }
}

// MARK: - AI

private struct AISettings: View {
    @AppStorage(Prefs.provider) private var providerRaw = ProviderKind.claudeCode.rawValue
    @AppStorage(Prefs.readEffort) private var readEffort = "low"
    @AppStorage(Prefs.threadEffort) private var threadEffort = "medium"

    @ViewState private var keyDraft = ""
    @ViewState private var keySaved = false
    @ViewState private var models: [String] = []
    @ViewState private var loadingModels = false
    @ViewState private var cliStatus = ""
    @ViewState private var testing = false
    @ViewState private var testOK = false
    @ViewState private var testText: String?
    @ViewState private var tick = 0  // redraws after writes to per-provider keys

    private var kind: ProviderKind { ProviderKind(rawValue: providerRaw) ?? .claudeCode }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $providerRaw) {
                    Section("On this Mac") {
                        ForEach(ProviderKind.local) { Text($0.label).tag($0.rawValue) }
                    }
                    Section("Cloud APIs") {
                        ForEach(ProviderKind.cloud) { Text($0.label).tag($0.rawValue) }
                    }
                }
                Text(kind.keyHint).font(.caption).foregroundStyle(.secondary)
            }

            Section(kind.label) {
                if kind.isCLI { cliRow }
                if kind.usesKey { keyRow }
                if kind.editableBaseURL {
                    TextField("Endpoint URL", text: stored(Prefs.baseURLKey(kind)),
                              prompt: Text(kind.defaultBaseURL.isEmpty ? "https://…/v1" : kind.defaultBaseURL))
                }
                modelRow
            }

            if kind.supportsEffort {
                Section("Effort") {
                    Picker("Margin notes", selection: $readEffort) {
                        Text("Quick").tag("low")
                        Text("Balanced").tag("medium")
                        Text("Deep").tag("high")
                    }
                    Picker("Thread replies", selection: $threadEffort) {
                        Text("Quick").tag("low")
                        Text("Balanced").tag("medium")
                        Text("Deep").tag("high")
                        Text("Deepest").tag("xhigh")
                    }
                }
            }

            Section {
                HStack(alignment: .top) {
                    Button(testing ? "Testing…" : "Test connection") { Task { await test() } }
                        .disabled(testing)
                    if let testText {
                        Label(testText, systemImage: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(testOK ? .green : .red)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
        .onAppear(perform: providerChanged)
        .onChange(of: providerRaw) { _, _ in providerChanged() }
    }

    // MARK: Rows

    private var cliRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Path to \(kind == .claudeCode ? "claude" : "codex")",
                      text: stored(kind == .claudeCode ? Prefs.claudePath : Prefs.codexPath),
                      prompt: Text("Auto-detect"))
            HStack {
                Text(cliStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Check") { Task { await checkCLI() } }.controlSize(.small)
            }
        }
    }

    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("API key", text: $keyDraft, prompt: Text(kind.keyRequired ? "Required" : "Optional"))
                    .onSubmit(saveKey)
                    .onChange(of: keyDraft) { _, new in keySaved = new == (Keychain.get(kind.rawValue) ?? "") && !new.isEmpty }
                Button("Save", action: saveKey).disabled(keySaved)
            }
            Text(keySaved ? "Saved in your macOS Keychain." : "Not saved yet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var modelRow: some View {
        HStack {
            TextField("Model", text: stored(Prefs.modelKey(kind)),
                      prompt: Text(kind == .codex ? "Codex default"
                                   : (kind.defaultModel.isEmpty ? "Pick or type a model" : kind.defaultModel)))
                .id("model-\(kind.rawValue)-\(tick)")
            if kind != .codex {
                Menu {
                    if models.isEmpty {
                        Text(loadingModels ? "Loading…" : "Press ↻ to load models")
                    }
                    ForEach(models, id: \.self) { m in
                        Button(m) {
                            UserDefaults.standard.set(m, forKey: Prefs.modelKey(kind))
                            tick += 1
                        }
                    }
                } label: {
                    Text("Choose")
                }
                .fixedSize()
                Button { Task { await loadModels() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Load the models this provider offers")
                .disabled(loadingModels)
            }
        }
    }

    // MARK: Actions

    /// A binding straight to a UserDefaults key whose name depends on the provider.
    private func stored(_ key: String) -> Binding<String> {
        Binding(get: { UserDefaults.standard.string(forKey: key) ?? "" },
                set: { UserDefaults.standard.set($0, forKey: key) })
    }

    private func providerChanged() {
        keyDraft = Keychain.get(kind.rawValue) ?? ""
        keySaved = !keyDraft.isEmpty
        models = []
        testText = nil
        cliStatus = ""
        tick += 1
        if kind.isCLI { Task { await checkCLI() } }
        if kind == .claudeCode { Task { await loadModels() } }
    }

    private func saveKey() {
        Keychain.set(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines), for: kind.rawValue)
        keySaved = !keyDraft.isEmpty
    }

    private func checkCLI() async {
        let url = kind == .claudeCode ? ClaudeCLI.locate() : CodexCLI.locate()
        guard let url else { cliStatus = "Not found."; return }
        cliStatus = await CLITool.version(url).map { "Found \($0)" } ?? "Found, but it didn't answer."
    }

    private func loadModels() async {
        if kind.usesKey, !keySaved, !keyDraft.isEmpty { saveKey() }
        loadingModels = true
        defer { loadingModels = false }
        do {
            models = try await LLM.listModels(kind)
            if models.isEmpty, kind != .claudeCode { show(false, "\(kind.label) didn't list any models.") }
        } catch {
            show(false, error.localizedDescription)
        }
    }

    private func test() async {
        if kind.usesKey, !keySaved, !keyDraft.isEmpty { saveKey() }
        testing = true
        testText = nil
        defer { testing = false }
        do {
            let llm = try LLM.make(kind)
            let result = try await llm.structured(
                prompt: Prompts.passage("We can skip writing tests because the code is simple.", note: nil, earlier: []),
                system: Prompts.system, schema: Prompts.thoughtsSchema, effort: "low")
            let first = (result["thoughts"] as? [[String: Any]])?.first?["text"] as? String
            show(true, first.map { "Connected. Sample note: “\($0)”" } ?? "Connected.")
        } catch {
            show(false, error.localizedDescription)
        }
    }

    private func show(_ ok: Bool, _ text: String) {
        testOK = ok
        testText = text
    }
}

// MARK: - Notes

private struct NotesSettings: View {
    @Environment(NoteStore.self) private var store

    var body: some View {
        Form {
            Section("Notes folder") {
                LabeledContent("Location") {
                    Text((store.folder.path as NSString).abbreviatingWithTildeInPath)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Change…", action: chooseFolder)
                    Button("Reveal in Finder") { store.revealFolder() }
                }
            }
            Section {
                Text("Each note is a plain Markdown file named after its first line, so you can open it in any editor or keep the folder in iCloud Drive. Margin notes are stored in a hidden .thinking folder beside the files. Changes made in other apps show up when you switch back.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.directoryURL = store.folder
        guard panel.runModal() == .OK, let url = panel.url,
              url.standardizedFileURL != store.folder.standardizedFileURL else { return }

        let alert = NSAlert()
        alert.messageText = "Copy your current notes to the new folder?"
        alert.informativeText = "Your notes stay in the old folder either way. Notes already in the new folder will show up too."
        alert.addButton(withTitle: "Copy Notes")
        alert.addButton(withTitle: "Don't Copy")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: store.switchFolder(to: url, bringNotes: true)
        case .alertSecondButtonReturn: store.switchFolder(to: url, bringNotes: false)
        default: break
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(Prefs.theme) private var theme = "system"
    @AppStorage(Prefs.pageFontSize) private var pageSize = 17.0
    @AppStorage(Prefs.marginFontSize) private var marginSize = 14.0

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $theme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: theme) { _, _ in AppAppearance.apply() }
            }
            Section("Text size") {
                LabeledContent("Page") {
                    HStack {
                        Slider(value: $pageSize, in: 13...24, step: 1)
                        Text("\(Int(pageSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Margin notes") {
                    HStack {
                        Slider(value: $marginSize, in: 12...18, step: 1)
                        Text("\(Int(marginSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section("Preview") {
                HStack(alignment: .top, spacing: 18) {
                    Text("We can skip writing tests because the code is simple.")
                        .font(.system(size: pageSize, design: .serif))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Simple for whom? What breaks first when someone else changes it?")
                        .font(Theme.inkFont(marginSize))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 180, alignment: .leading)
                }
                .padding(14)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }
}
