import Foundation
import Security
#if os(macOS)
import AppKit
#endif
import WhyNodeCore

/// 앱 화면 언어. 원문은 영어이고 한국어 번역이 있다.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case korean = "ko"

    var id: String { rawValue }

    /// 언어 이름은 그 언어로 쓴다.
    var displayName: String {
        switch self {
        case .english: "English"
        case .korean: "한국어"
        }
    }
}

/// 앱 전역 설정. 선택한 AI 회사 · 연결 방식 · 모델은 UserDefaults에, API 키는 Keychain에만 저장한다 (SPEC 5.2, 5.4).
@Observable
final class SettingsStore {
    private static let settingsKey = "ai.settings"
    private static let physicsKey = "physics.settings"
    private static let textScaleKey = "text.scale"
    private static let projectFolderKey = "project.folder"
    private static let languageKey = "app.language"

    /// 화면 언어. 기본은 영어. 바꾸면 앱을 다시 켜야 적용된다(메뉴 · 시스템 창까지 한 번에 바뀌도록 AppleLanguages로 정한다).
    var language: AppLanguage = .english {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
    /// 이번 실행에 적용된 언어
    @ObservationIgnored private var launchLanguage: AppLanguage = .english
    var needsRestartForLanguage: Bool { language != launchLanguage }

    private(set) var ai: AISettings?

    /// 시뮬레이션 조절값 (SPEC 2.6). 프로젝트와 상관없이 앱 전체에서 유지한다.
    var physics: PhysicsSettings = .default {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(physics), forKey: Self.physicsKey) }
    }

    /// 캔버스 글자 크기 배율. 노드 크기는 그대로 두고 글자만 키운다. 앱 전체에서 유지한다.
    var textScale: Double = 1 {
        didSet { UserDefaults.standard.set(textScale, forKey: Self.textScaleKey) }
    }

    static let textScaleRange: ClosedRange<Double> = 0.8...1.8
    static let textScaleStep = 0.1

    /// 한 단계 키우거나(+1) 줄인다(-1). 0.1 단위로 맞춰 부동소수 오차가 쌓이지 않게 한다.
    func stepTextScale(_ direction: Int) {
        let next = ((textScale + Double(direction) * Self.textScaleStep) * 10).rounded() / 10
        textScale = min(max(next, Self.textScaleRange.lowerBound), Self.textScaleRange.upperBound)
    }

    /// 선저장 폴더를 사용자가 고른 경우의 경로. nil이면 기본 폴더(~/Documents/WhyNode).
    var customProjectFolder: String? {
        didSet { UserDefaults.standard.set(customProjectFolder, forKey: Self.projectFolderKey) }
    }

    #if os(macOS)
    var projectFolder: URL {
        customProjectFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ProjectFiles.defaultFolder
    }
    #endif

    var isConfigured: Bool { ai != nil }

    #if os(macOS)
    /// 앱을 다시 켠다. 문서는 자동 저장되어 있다.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    #endif

    init() {
        // 화면 문구를 읽기 전에 언어를 정한다. 이 객체는 앱이 시작할 때 가장 먼저 만들어진다.
        let saved = UserDefaults.standard.string(forKey: Self.languageKey).flatMap(AppLanguage.init) ?? .english
        UserDefaults.standard.set([saved.rawValue], forKey: "AppleLanguages")
        language = saved
        launchLanguage = saved
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey) {
            ai = try? JSONDecoder().decode(AISettings.self, from: data)
        }
        if let data = UserDefaults.standard.data(forKey: Self.physicsKey),
           let saved = try? JSONDecoder().decode(PhysicsSettings.self, from: data) {
            physics = saved.clamped
        }
        customProjectFolder = UserDefaults.standard.string(forKey: Self.projectFolderKey)
        let savedScale = UserDefaults.standard.double(forKey: Self.textScaleKey)
        if Self.textScaleRange.contains(savedScale) { textScale = savedScale }
    }

    func save(_ settings: AISettings, apiKey: String?) throws {
        if settings.connection == .apiKey, let apiKey {
            try Keychain.setAPIKey(apiKey, for: settings.provider)
        }
        UserDefaults.standard.set(try JSONEncoder().encode(settings), forKey: Self.settingsKey)
        ai = settings
        #if os(macOS)
        // agy를 더 쓰지 않으면 상시 연결을 닫는다.
        if !(settings.connection == .cli && settings.provider == .google), let client = acpClient {
            acpClient = nil
            Task { await client.shutdown() }
        }
        #endif
    }

    #if os(macOS)
    /// agy 상시 연결. 앱 실행 동안 하나만 유지한다.
    @ObservationIgnored private var acpClient: ACPClient?

    private func sharedACPClient(executable: URL) -> ACPClient {
        if let acpClient, acpClient.executable == executable { return acpClient }
        if let old = acpClient { Task { await old.shutdown() } }
        let client = ACPClient(executable: executable)
        acpClient = client
        return client
    }
    #endif

    /// 저장된 설정으로 프로바이더를 만든다. 설정 전이면 nil.
    func makeProvider() throws -> (any AIProvider)? {
        guard let ai else { return nil }
        return try makeProvider(ai, apiKey: Keychain.apiKey(for: ai.provider))
    }

    /// CLI 위치를 백그라운드에서 미리 찾아 두어 맵 화면이 로그인 셸 실행을 기다리지 않게 한다.
    /// agy는 상시 연결도 미리 열어 첫 요청을 기다리지 않게 한다.
    func warmUp() {
        #if os(macOS)
        guard let ai, ai.connection == .cli, ai.provider.supportsCLI else { return }
        let tool = ai.provider.cliTool
        Task {
            let executable = await Task.detached { CLIProvider.locate(tool) }.value
            guard let executable, ai.provider == .google else { return }
            try? await sharedACPClient(executable: executable).start()
        }
        #endif
    }

    func makeProvider(_ settings: AISettings, apiKey: String?) throws -> any AIProvider {
        switch settings.connection {
        case .apiKey:
            guard let apiKey, !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
            let model = settings.model.isEmpty ? settings.provider.defaultAPIModel : settings.model
            switch settings.provider {
            case .google: return GeminiProvider(apiKey: apiKey, model: model)
            case .anthropic: return AnthropicProvider(apiKey: apiKey, model: model)
            case .openai: return OpenAIProvider(apiKey: apiKey, model: model)
            }
        case .cli:
            #if os(macOS)
            guard settings.provider.supportsCLI else { throw ProviderError.notSupported(settings.provider.cliDisplayName) }
            guard let executable = CLIProvider.locate(settings.provider.cliTool) else {
                throw ProviderError.cliNotFound(settings.provider.cliTool)
            }
            if settings.provider == .google {
                return ACPProvider(client: sharedACPClient(executable: executable), model: settings.model)
            }
            return CLIProvider(kind: settings.provider, executable: executable, model: settings.model)
            #else
            throw ProviderError.notSupported(String(localized: "CLI connection on iPadOS"))
            #endif
        case .oauth:
            throw ProviderError.notSupported(String(localized: "Official sign-in"))
        }
    }
}

enum Keychain {
    private static let service = "com.pargame.whynode.apikey"

    static func apiKey(for provider: ProviderKind) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setAPIKey(_ key: String, for provider: ProviderKind) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(baseQuery(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(provider)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    private static func baseQuery(_ provider: ProviderKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { String(localized: "Couldn't save to Keychain (\(Int(status)))") }
    }
}
