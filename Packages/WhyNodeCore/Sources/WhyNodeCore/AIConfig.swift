import Foundation

/// AI 회사. 연결 방식(①②③)과 별개로 고른다 (SPEC 5.4).
public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case google, anthropic, openai

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .google: "Google Gemini"
        case .anthropic: "Anthropic Claude"
        case .openai: "OpenAI"
        }
    }

    /// ③ 공식 CLI의 실행 파일 이름
    public var cliTool: String {
        switch self {
        case .google: "agy"
        case .anthropic: "claude"
        case .openai: "codex"
        }
    }

    public var cliDisplayName: String {
        switch self {
        case .google: "Antigravity CLI (agy)"
        case .anthropic: "Claude Code (claude)"
        case .openai: "Codex CLI (codex)"
        }
    }

    /// 이 앱이 CLI 호출 형식을 확인해 지원하는 CLI
    public var supportsCLI: Bool { self != .openai }

    /// 터미널에 붙여 넣는 공식 설치 명령. 지원하지 않는 CLI는 nil.
    public var cliInstallCommand: String? {
        switch self {
        case .google: "curl -fsSL https://antigravity.google/cli/install.sh | bash"
        case .anthropic: "curl -fsSL https://claude.ai/install.sh | bash"
        case .openai: nil
        }
    }

    /// API Key 연결의 기본 모델. 비어 있으면 모델 목록에서 고른다.
    public var defaultAPIModel: String {
        switch self {
        case .anthropic: "claude-sonnet-5-5"
        case .google, .openai: ""
        }
    }

    public var apiKeyHelp: String {
        switch self {
        case .google: L("Get a key from Google AI Studio (aistudio.google.com)")
        case .anthropic: L("Get a key from Anthropic Console (console.anthropic.com)")
        case .openai: L("Get a key from OpenAI Platform (platform.openai.com)")
        }
    }
}

/// 앱에 저장하는 AI 설정. API Key 같은 인증 정보는 담지 않는다 (SPEC 5.2).
public struct AISettings: Codable, Equatable, Sendable {
    public var provider: ProviderKind
    public var connection: Connection
    /// 비어 있으면 CLI 기본 모델 또는 프로바이더 기본 모델을 쓴다.
    public var model: String

    public init(provider: ProviderKind, connection: Connection, model: String = "") {
        self.provider = provider
        self.connection = connection
        self.model = model
    }

    public var summary: String {
        let method = switch connection {
        case .apiKey: L("API Key")
        case .oauth: L("Official Sign-in")
        case .cli: L("My CLI")
        }
        let modelText = model.isEmpty ? "" : " · \(model)"
        return "\(provider.displayName) · \(method)\(modelText)"
    }
}

public enum ProviderError: Error, LocalizedError, Equatable {
    case http(status: Int, message: String)
    case emptyResponse
    case unreadableResponse(String)
    case cliNotFound(String)
    case cliFailed(String)
    case timeout
    case notSupported(String)
    case missingAPIKey
    case missingModel
    case invalidModel(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message): L("AI server error (\(status)): \(message)")
        case .emptyResponse: L("The AI sent an empty response.")
        case .unreadableResponse(let detail): L("Couldn't read the AI response: \(detail)")
        case .cliNotFound(let tool): L("Couldn't find the \(tool) CLI. See Help > Connecting AI to install it.")
        case .cliFailed(let message): L("CLI failed: \(message)")
        case .timeout: L("The AI took too long to respond.")
        case .notSupported(let what): L("\(what) isn't supported yet.")
        case .missingAPIKey: L("No API key. Enter one in Settings.")
        case .missingModel: L("Choose a model.")
        case .invalidModel(let model): L("“\(model)” isn't a valid model ID. Use only letters, numbers, and . _ -")
        }
    }
}

/// 연결 테스트용 최소 요청 (SPEC 5.4-3)
public enum ConnectionTest {
    public static var context: ContextPackage {
        ContextPackage(
            kind: .suggest, topic: "무지개", path: [], parentAnswer: nil, question: "무지개",
            answer: "무지개는 햇빛이 물방울 안에서 굴절 · 반사되며 파장별로 나뉘어 보이는 현상입니다.",
            siblings: nil, children: [], index: [], exclude: []
        )
    }

    public static func run(_ provider: any AIProvider) async throws -> [String] {
        let response = try await provider.suggest(context)
        guard !response.suggestions.isEmpty else { throw ProviderError.emptyResponse }
        return response.suggestions
    }
}
