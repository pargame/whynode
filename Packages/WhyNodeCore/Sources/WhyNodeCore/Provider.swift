import Foundation

public struct ProviderCapabilities: Equatable, Sendable {
    public var structuredOutput: Bool
    public var maxConcurrentRequests: Int

    public init(structuredOutput: Bool, maxConcurrentRequests: Int) {
        self.structuredOutput = structuredOutput
        self.maxConcurrentRequests = maxConcurrentRequests
    }
}

/// 연결 방식(API Key · 공식 OAuth · 공식 CLI)과 무관한 공통 인터페이스 (SPEC 5.3)
public protocol AIProvider: Sendable {
    var name: String { get }
    var connection: Connection { get }
    var model: String { get }
    var capabilities: ProviderCapabilities { get }

    func answer(_ context: ContextPackage) async throws -> AnswerResponse
    func suggest(_ context: ContextPackage) async throws -> SuggestResponse
    func links(_ context: ContextPackage) async throws -> LinksResponse
}

extension AIProvider {
    public func generation(at date: Date = Date()) -> Generation {
        Generation(provider: name, connection: connection, model: model, promptVersion: Prompt.version, generatedAt: Timestamp.truncated(date))
    }
}

/// 실제 AI 연결 전 UI · 흐름 확인용 가짜 프로바이더
public struct MockProvider: AIProvider {
    public let name = "mock"
    public let connection = Connection.cli
    public let model = "mock-1"
    public let capabilities = ProviderCapabilities(structuredOutput: true, maxConcurrentRequests: 4)
    public var delay: Duration

    public init(delay: Duration = .milliseconds(900)) {
        self.delay = delay
    }

    public func answer(_ context: ContextPackage) async throws -> AnswerResponse {
        try await Task.sleep(for: delay)
        let q = context.question
        let core = q.count > 18 ? String(q.prefix(18)) + "…" : q
        return AnswerResponse(
            answer: "‘\(q)’에 대한 가짜 해설입니다. 실제 AI를 연결하면 이 자리에 원리와 메커니즘 위주의 3~4문장 답변이 들어갑니다. 지금은 노드 생성 · 확장 흐름을 확인하는 용도입니다.",
            summary: "\(core)의 가짜 요약",
            suggestions: [
                "\(core)의 원리는 무엇일까?",
                "\(core)은(는) 왜 중요할까?",
                "\(core)의 한계는 어디까지일까?",
            ]
        )
    }

    public func suggest(_ context: ContextPackage) async throws -> SuggestResponse {
        try await Task.sleep(for: delay)
        let core = String(context.question.prefix(18))
        let round = (context.exclude?.count ?? 0) + 1
        return SuggestResponse(suggestions: [
            "\(core)을(를) 다른 관점에서 보면? (\(round))",
            "\(core)과(와) 비슷한 예는 무엇이 있을까? (\(round))",
            "\(core)을(를) 실제로 어떻게 활용할까? (\(round))",
        ])
    }

    public func links(_ context: ContextPackage) async throws -> LinksResponse {
        try await Task.sleep(for: delay)
        let ids = context.index.map(\.id)
        guard ids.count >= 3 else { return LinksResponse(links: []) }
        return LinksResponse(links: [.init(a: ids[ids.count - 1], b: ids[1], reason: "가짜 연결")])
    }
}
