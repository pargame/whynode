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

    /// API Key 연결의 기본 모델. 비어 있으면 모델 목록에서 고른다.
    public var defaultAPIModel: String {
        switch self {
        case .anthropic: "claude-sonnet-5-5"
        case .google, .openai: ""
        }
    }

    public var apiKeyHelp: String {
        switch self {
        case .google: "Google AI Studio(aistudio.google.com)에서 발급"
        case .anthropic: "Anthropic Console(console.anthropic.com)에서 발급"
        case .openai: "OpenAI Platform(platform.openai.com)에서 발급"
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
        case .apiKey: "API 키"
        case .oauth: "공식 로그인"
        case .cli: "내 CLI"
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

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message): "AI 서버 오류 (\(status)): \(message)"
        case .emptyResponse: "AI가 빈 응답을 보냈습니다."
        case .unreadableResponse(let detail): "AI 응답을 해석하지 못했습니다: \(detail)"
        case .cliNotFound(let tool): "\(tool) CLI를 찾지 못했습니다. 설치와 로그인을 확인해 주세요."
        case .cliFailed(let message): "CLI 실행 실패: \(message)"
        case .timeout: "AI 응답 시간이 초과됐습니다."
        case .notSupported(let what): "\(what)은(는) 아직 지원하지 않습니다."
        case .missingAPIKey: "API 키가 없습니다. 설정에서 입력해 주세요."
        case .missingModel: "모델을 선택해 주세요."
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
