import SwiftUI
import WhyNodeCore

/// AI 회사 · 연결 방식 선택과 연결 테스트 (SPEC 5.4). 첫 실행 안내와 설정 화면이 같은 화면을 쓴다.
struct AISetupView: View {
    enum Mode {
        case onboarding, settings
    }

    let mode: Mode
    var onFinish: () -> Void = {}

    @Environment(SettingsStore.self) private var settings

    @State private var provider: ProviderKind = .google
    @State private var connection: Connection = Self.defaultConnection
    @State private var model = ""
    @State private var apiKey = ""
    @State private var models: [String] = []
    @State private var cliPath: String?
    @State private var cliChecked = false
    @State private var testState: TestState = .idle
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
                    Text("AI 연결 설정").font(.title2.bold())
                    Text("WhyNode가 답변과 추가 질문을 만들 때 쓸 AI를 고릅니다. 나중에 설정에서 언제든 바꿀 수 있습니다.")
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                Picker("AI 회사", selection: $provider) {
                    ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
                }

                Picker("연결 방식", selection: $connection) {
                    #if os(macOS)
                    Text("내 CLI (구독 요금제)").tag(Connection.cli)
                    #endif
                    Text("API 키").tag(Connection.apiKey)
                    Text("공식 로그인 (준비 중)").tag(Connection.oauth)
                }

                switch connection {
                case .cli: cliSection
                case .apiKey: apiKeySection
                case .oauth:
                    Text("공식 로그인은 각 AI 회사에 WhyNode 앱 등록이 끝나면 지원합니다. 지금은 내 CLI 또는 API 키를 사용해 주세요.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            testResult

            HStack {
                if mode == .settings, let current = settings.ai {
                    Text("현재: \(current.summary)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if mode == .onboarding {
                    Button("나중에") { onFinish() }
                }
                Button("연결 테스트") { runTest() }
                    .disabled(!canTest || testState == .running)
                Button(mode == .onboarding ? "시작하기" : "저장") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isPassed)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
        .onAppear(perform: loadCurrent)
        .onChange(of: provider) { resetForChange(); checkCLI() }
        .onChange(of: connection) { resetForChange(); checkCLI() }
        .onChange(of: model) { testState = .idle }
        .onChange(of: apiKey) { testState = .idle }
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
            Text("\(provider.cliDisplayName) 연동은 아직 지원하지 않습니다. API 키를 사용해 주세요.")
                .foregroundStyle(.secondary)
        } else if !cliChecked {
            HStack { ProgressView().controlSize(.small); Text("\(provider.cliTool) 찾는 중…") }
        } else if let cliPath {
            LabeledContent("CLI", value: cliPath)
            Picker("모델", selection: cliModelSelection) {
                Text("CLI 기본 모델").tag("")
                ForEach(cliModels) { Text($0.name).tag($0.id) }
                Text("직접 입력…").tag(Self.customTag)
            }
            if customModel {
                TextField("모델 ID", text: $model)
            }
            if provider == .anthropic {
                Text("빠른 응답과 적은 사용량을 원하면 Haiku를 권장합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("이 Mac에서 \(provider.cliTool)에 로그인되어 있으면 그 계정의 구독 요금제를 그대로 씁니다. WhyNode는 로그인 정보를 다루지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("\(provider.cliDisplayName)를 찾지 못했습니다. 설치하고 터미널에서 한 번 로그인한 뒤 다시 확인해 주세요.")
                .foregroundStyle(.orange)
            Button("다시 확인") { checkCLI() }
        }
    }

    @ViewBuilder
    private var apiKeySection: some View {
        SecureField("API 키", text: $apiKey)
        Text("\(provider.apiKeyHelp). 키는 이 기기의 Keychain에만 저장됩니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            if models.isEmpty {
                TextField("모델", text: $model, prompt: Text(provider.defaultAPIModel.isEmpty ? "모델 목록을 불러와 고르세요" : provider.defaultAPIModel))
            } else {
                Picker("모델", selection: $model) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
            Button(loadingModels ? "불러오는 중…" : "모델 목록 불러오기") { loadModels() }
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
            Text(mode == .onboarding ? "연결 테스트에 성공하면 시작할 수 있습니다." : "설정을 바꾸면 연결 테스트 후 저장할 수 있습니다.")
                .font(.callout).foregroundStyle(.secondary)
        case .running:
            HStack { ProgressView().controlSize(.small); Text("연결 테스트 중… CLI는 수십 초 걸릴 수 있습니다.") }
        case .passed(let samples):
            VStack(alignment: .leading, spacing: 4) {
                Label("연결 성공", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("받은 예시 질문: \(samples.prefix(2).joined(separator: " / "))")
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
        testState = .idle
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
        testState = .running
        let draft = draft
        let key = apiKey
        Task {
            do {
                let provider = try SettingsStore.makeProvider(draft, apiKey: key)
                let samples = try await ConnectionTest.run(provider)
                testState = .passed(samples)
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
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
