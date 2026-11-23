import Foundation
import Security
import WhyNodeCore

/// 앱 전역 설정. 선택한 AI 회사 · 연결 방식 · 모델은 UserDefaults에, API 키는 Keychain에만 저장한다 (SPEC 5.2, 5.4).
@Observable
final class SettingsStore {
    private static let settingsKey = "ai.settings"

    private(set) var ai: AISettings?

    var isConfigured: Bool { ai != nil }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey) {
            ai = try? JSONDecoder().decode(AISettings.self, from: data)
        }
    }

    func save(_ settings: AISettings, apiKey: String?) throws {
        if settings.connection == .apiKey, let apiKey {
            try Keychain.setAPIKey(apiKey, for: settings.provider)
        }
        UserDefaults.standard.set(try JSONEncoder().encode(settings), forKey: Self.settingsKey)
        ai = settings
    }

    /// 저장된 설정으로 프로바이더를 만든다. 설정 전이면 nil.
    func makeProvider() throws -> (any AIProvider)? {
        guard let ai else { return nil }
        return try Self.makeProvider(ai, apiKey: Keychain.apiKey(for: ai.provider))
    }

    static func makeProvider(_ settings: AISettings, apiKey: String?) throws -> any AIProvider {
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
            return CLIProvider(kind: settings.provider, executable: executable, model: settings.model)
            #else
            throw ProviderError.notSupported("iPadOS의 CLI 연동")
            #endif
        case .oauth:
            throw ProviderError.notSupported("공식 로그인")
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
        var errorDescription: String? { "Keychain 저장 실패 (\(status))" }
    }
}
