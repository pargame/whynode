import SwiftUI
import UniformTypeIdentifiers
import WhyNodeCore

/// AI 회사 · 연결 방식 선택과 연결 테스트 (SPEC 5.4). 첫 실행 안내와 설정 화면이 같은 화면을 쓴다.
struct AISetupView: View {
    enum Mode {
        case onboarding, settings
    }

    let mode: Mode
    var onFinish: () -> Void = {}

    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFolder = false

    @State private var provider: ProviderKind = .google
    @State private var connection: Connection = Self.defaultConnection
    @State private var model = ""
    @State private var apiKey = ""
    @State private var models: [String] = []
    @State private var cliPath: String?
    @State private var cliChecked = false
    @State private var testState: TestState = .idle
    /// 진행 중인 연결 테스트. 설정을 바꾸거나 다시 누르거나 화면을 닫으면 끊는다(실제 요청이라 토큰이 든다).
    @State private var testTask: Task<Void, Never>?
    @State private var loadingModels = false
    @State private var modelError: String?
    @State private var cliModels: [CLIModel] = []
    @State private var customModel = false

    enum TestState: Equatable {
        case idle, running, passed([String]), failed(String)
    }

    private static var defaultConnection: Connection {
        #if os(macOS)
        .cli
        #else
        .apiKey
        #endif
    }

    private var draft: AISettings { AISettings(provider: provider, connection: connection, model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if mode == .onboarding {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Connection").font(.title2.bold())
                    Text("Choose the AI WhyNode uses to write answers and suggestions. You can change it anytime in Settings.")
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                Picker("AI Provider", selection: $provider) {
                    ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
                }

                Picker("Connection", selection: $connection) {
                    #if os(macOS)
                    Text("My CLI (subscription)").tag(Connection.cli)
                    #endif
                    Text("API Key").tag(Connection.apiKey)
                    Text("Official Sign-in (coming soon)").tag(Connection.oauth)
                }

                switch connection {
                case .cli: cliSection
                case .apiKey: apiKeySection
                case .oauth:
                    Text("Official sign-in will be available once WhyNode is registered with each AI provider. For now, use your CLI or an API key.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            #if os(macOS)
            if mode == .settings {
                @Bindable var settings = settings
                Form {
                    Section("General") {
                        Picker("Language", selection: $settings.language) {
                            ForEach(AppLanguage.allCases) { Text(verbatim: $0.displayName).tag($0) }
                        }
                        if settings.needsRestartForLanguage {
                            HStack {
                                Text("Restart WhyNode to apply the language.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Restart Now") { settings.relaunch() }
                            }
                        }
                    }
                    Section("Projects") {
                        LabeledContent("Save Location") {
                            HStack {
                                Text(settings.projectFolder.path(percentEncoded: false))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                                Button("Change") { choosingFolder = true }
                                if settings.customProjectFolder != nil {
                                    Button("Default Location") { settings.customProjectFolder = nil }
                                }
                            }
                        }
                        Text("New projects are saved here right away and saved automatically afterward. The file name follows the first node's topic.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .frame(height: 210)
                .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result {
                        settings.customProjectFolder = url.path(percentEncoded: false)
                    }
                }
            }
            #endif

            testResult

            HStack {
                if mode == .settings, let current = settings.ai {
                    Text("Current: \(current.summary)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if mode == .onboarding {
                    Button("Later") { onFinish() }
                } else {
                    // 시트로 열렸을 때 닫을 방법이 Esc뿐이라 버튼을 둔다. 바뀐 AI 설정은 저장하지 않는다.
                    Button("Close") {
                        onFinish()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                Button("Test Connection") { runTest() }
                    .disabled(!canTest || testState == .running)
                Button(mode == .onboarding ? "Get Started" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isPassed)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
        .onAppear(perform: loadCurrent)
        .onDisappear { cancelTest() }
        .onChange(of: provider) { resetForChange(); checkCLI() }
        .onChange(of: connection) { resetForChange(); checkCLI() }
        .onChange(of: model) { cancelTest() }
        .onChange(of: apiKey) { cancelTest() }
        .task(id: apiKey) {
            // 입력이 멈추면 모델 목록을 자동으로 불러온다.
            guard connection == .apiKey, !apiKey.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            loadModels()
        }
    }

    // 연결 방식별 입력

    @ViewBuilder
    private var cliSection: some View {
        if !provider.supportsCLI {
            Text("\(provider.cliDisplayName) isn't supported yet. Please use an API key.")
                .foregroundStyle(.secondary)
        } else if !cliChecked {
            HStack { ProgressView().controlSize(.small); Text("Looking for \(provider.cliTool)…") }
        } else if let cliPath {
            LabeledContent("CLI", value: cliPath)
            Picker("Model", selection: cliModelSelection) {
                Text("CLI Default Model").tag("")
                ForEach(cliModels) { Text($0.name).tag($0.id) }
                Text("Custom").tag(Self.customTag)
            }
            if customModel {
                TextField("Model ID", text: $model)
            }
            switch provider {
            case .anthropic:
                Text("For fast responses and lower usage, Haiku is recommended.")
                    .font(.caption).foregroundStyle(.secondary)
            case .google:
                Text("WhyNode keeps a connection to agy while the app is open. For fast responses, Gemini 3.8 Flash (Low) is recommended.")
                    .font(.caption).foregroundStyle(.secondary)
            case .openai:
                EmptyView()
            }
            Text("If \(provider.cliTool) is signed in on this Mac, WhyNode uses that account's subscription. WhyNode never handles your sign-in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Couldn't find \(provider.cliDisplayName). Install it, sign in once in Terminal, then check again.")
                .foregroundStyle(.orange)
            Button("Check Again") { checkCLI() }
        }
    }

    @ViewBuilder
    private var apiKeySection: some View {
        SecureField("API Key", text: $apiKey)
        Text("\(provider.apiKeyHelp). The key is stored only in this device's Keychain.")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            if models.isEmpty {
                TextField("Model", text: $model, prompt: provider.defaultAPIModel.isEmpty ? Text("Load the model list and choose") : Text(verbatim: provider.defaultAPIModel))
            } else {
                Picker("Model", selection: $model) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
            Button(loadingModels ? "Loading…" : "Load Models") { loadModels() }
                .disabled(apiKey.isEmpty || loadingModels)
        }
        if let modelError {
            Text(modelError).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .idle:
            Text(mode == .onboarding ? "You can get started once the connection test passes." : "After changing settings, test the connection to save.")
                .font(.callout).foregroundStyle(.secondary)
        case .running:
            HStack { ProgressView().controlSize(.small); Text("Testing connection… CLI can take tens of seconds.") }
        case .passed(let samples):
            VStack(alignment: .leading, spacing: 4) {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Sample questions: \(samples.prefix(2).joined(separator: " / "))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3)
        }
    }

    // 동작

    private var isPassed: Bool {
        if case .passed = testState { return true }
        return false
    }

    private var canTest: Bool {
        switch connection {
        case .cli: provider.supportsCLI && cliPath != nil
        case .apiKey: !apiKey.isEmpty && !(model.isEmpty && provider.defaultAPIModel.isEmpty)
        case .oauth: false
        }
    }

    typealias CLIModel = ModelOption
    private static let customTag = "__custom__"

    /// 목록에 없는 모델이 저장돼 있으면 직접 입력 상태로 보여준다.
    private var cliModelSelection: Binding<String> {
        Binding(
            get: { customModel ? Self.customTag : model },
            set: { value in
                if value == Self.customTag {
                    customModel = true
                } else {
                    customModel = false
                    model = value
                }
            }
        )
    }

    private func loadCLIModels(executable: URL) {
        #if os(macOS)
        let kind = provider
        Task {
            let list = (try? await CLIProvider.models(kind: kind, executable: executable)) ?? []
            guard kind == provider else { return }
            cliModels = list
            customModel = !model.isEmpty && !list.contains { $0.id == model }
        }
        #endif
    }

    private func loadCurrent() {
        if let current = settings.ai {
            provider = current.provider
            connection = current.connection
            model = current.model
            apiKey = Keychain.apiKey(for: current.provider) ?? ""
        }
        checkCLI()
    }

    private func resetForChange() {
        cancelTest()
        models = []
        cliModels = []
        customModel = false
        modelError = nil
        if settings.ai?.provider == provider, settings.ai?.connection == connection {
            model = settings.ai?.model ?? ""
        } else {
            model = ""
        }
        apiKey = Keychain.apiKey(for: provider) ?? ""
    }

    private func checkCLI() {
        guard connection == .cli else { return }
        #if os(macOS)
        cliChecked = false
        let tool = provider.cliTool
        Task {
            let found = await Task.detached { CLIProvider.locate(tool) }.value
            guard tool == provider.cliTool else { return }
            cliPath = found?.path
            cliChecked = true
            if let found { loadCLIModels(executable: found) }
        }
        #endif
    }

    private func loadModels() {
        loadingModels = true
        modelError = nil
        let key = apiKey
        let provider = provider
        Task {
            defer { loadingModels = false }
            do {
                let list = switch provider {
                case .google: try await GeminiProvider.models(apiKey: key)
                case .anthropic: try await AnthropicProvider.models(apiKey: key)
                case .openai: try await OpenAIProvider.models(apiKey: key)
                }
                models = list
                if !list.contains(model) {
                    model = list.contains(provider.defaultAPIModel) ? provider.defaultAPIModel : (list.first ?? "")
                }
            } catch {
                modelError = error.localizedDescription
            }
        }
    }

    private func runTest() {
        testTask?.cancel()
        testState = .running
        let draft = draft
        let key = apiKey
        testTask = Task {
            do {
                let provider = try settings.makeProvider(draft, apiKey: key)
                let samples = try await ConnectionTest.run(provider)
                // 끊긴 테스트의 늦은 결과가 지금 상태를 덮지 않게 한다.
                guard !Task.isCancelled else { return }
                testState = .passed(samples)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                testState = .failed(error.localizedDescription)
            }
        }
    }

    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
        testState = .idle
    }

    private func save() {
        do {
            try settings.save(draft, apiKey: connection == .apiKey ? apiKey : nil)
            onFinish()
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }
}
