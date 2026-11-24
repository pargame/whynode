import Foundation

/// ① API Key 연결 공통 처리
enum HTTP {
    static let timeout: TimeInterval = 120

    static func post(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    static func get(_ url: URL, headers: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 30)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return try await send(request)
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw ProviderError.timeout
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProviderError.http(status: status, message: errorMessage(object) ?? String(decoding: data.prefix(300), as: UTF8.self))
        }
        return object
    }

    /// 세 회사 모두 `{"error": {"message": ...}}` 형태로 오류를 돌려준다.
    private static func errorMessage(_ object: [String: Any]) -> String? {
        (object["error"] as? [String: Any])?["message"] as? String
    }
}

public struct GeminiProvider: AIProvider {
    public let name = "google"
    public let connection = Connection.apiKey
    public let model: String
    public let capabilities = ProviderCapabilities(structuredOutput: true, maxConcurrentRequests: 4)
    private let apiKey: String

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    public func answer(_ context: ContextPackage) async throws -> AnswerResponse {
        try await JSONExtract.decode(AnswerResponse.self, from: generate(context))
    }

    public func suggest(_ context: ContextPackage) async throws -> SuggestResponse {
        try await JSONExtract.decode(SuggestResponse.self, from: generate(context))
    }

    private func generate(_ context: ContextPackage) async throws -> String {
        guard !model.isEmpty else { throw ProviderError.missingModel }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": Prompt.system]]],
            "contents": [["role": "user", "parts": [["text": Prompt.userMessage(for: context)]]]],
            "generationConfig": ["responseMimeType": "application/json"],
        ]
        let object = try await HTTP.post(url, headers: ["x-goog-api-key": apiKey], body: body)
        if let meta = object["usageMetadata"] as? [String: Any] {
            UsageMeter.record(TokenUsage(inputTokens: UsageMeter.int(meta["promptTokenCount"]), outputTokens: UsageMeter.int(meta["candidatesTokenCount"]) + UsageMeter.int(meta["thoughtsTokenCount"])))
        }
        let parts = (((object["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw ProviderError.emptyResponse }
        return text
    }

    /// 텍스트 생성을 지원하는 모델 목록
    public static func models(apiKey: String) async throws -> [String] {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!
        let object = try await HTTP.get(url, headers: ["x-goog-api-key": apiKey])
        let models = object["models"] as? [[String: Any]] ?? []
        return models.compactMap { model in
            guard let name = model["name"] as? String,
                  (model["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true
            else { return nil }
            return name.replacingOccurrences(of: "models/", with: "")
        }
        .sorted()
    }
}

public struct AnthropicProvider: AIProvider {
    public let name = "anthropic"
    public let connection = Connection.apiKey
    public let model: String
    public let capabilities = ProviderCapabilities(structuredOutput: true, maxConcurrentRequests: 4)
    private let apiKey: String

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    public func answer(_ context: ContextPackage) async throws -> AnswerResponse {
        try await JSONExtract.decode(AnswerResponse.self, from: respond(context))
    }

    public func suggest(_ context: ContextPackage) async throws -> SuggestResponse {
        try await JSONExtract.decode(SuggestResponse.self, from: respond(context))
    }

    /// 응답 형식은 도구 하나를 강제 호출하게 해 스키마로 받는다.
    private func respond(_ context: ContextPackage) async throws -> String {
        guard !model.isEmpty else { throw ProviderError.missingModel }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": Prompt.system,
            "messages": [["role": "user", "content": Prompt.userMessage(for: context)]],
            "tools": [[
                "name": "respond",
                "description": "Return the WhyNode response in the given format.",
                "input_schema": Prompt.schemaObject(for: context.kind),
            ]],
            "tool_choice": ["type": "tool", "name": "respond"],
        ]
        let object = try await HTTP.post(
            URL(string: "https://api.anthropic.com/v1/messages")!,
            headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"],
            body: body
        )
        if let usage = object["usage"] as? [String: Any] {
            let input = UsageMeter.int(usage["input_tokens"]) + UsageMeter.int(usage["cache_creation_input_tokens"]) + UsageMeter.int(usage["cache_read_input_tokens"])
            UsageMeter.record(TokenUsage(inputTokens: input, outputTokens: UsageMeter.int(usage["output_tokens"])))
        }
        let blocks = object["content"] as? [[String: Any]] ?? []
        guard let input = blocks.first(where: { $0["type"] as? String == "tool_use" })?["input"] else {
            throw ProviderError.emptyResponse
        }
        let data = try JSONSerialization.data(withJSONObject: input)
        return String(decoding: data, as: UTF8.self)
    }

    public static func models(apiKey: String) async throws -> [String] {
        let object = try await HTTP.get(
            URL(string: "https://api.anthropic.com/v1/models?limit=100")!,
            headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
        )
        return (object["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }
}

public struct OpenAIProvider: AIProvider {
    public let name = "openai"
    public let connection = Connection.apiKey
    public let model: String
    public let capabilities = ProviderCapabilities(structuredOutput: false, maxConcurrentRequests: 4)
    private let apiKey: String

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    public func answer(_ context: ContextPackage) async throws -> AnswerResponse {
        try await JSONExtract.decode(AnswerResponse.self, from: complete(context))
    }

    public func suggest(_ context: ContextPackage) async throws -> SuggestResponse {
        try await JSONExtract.decode(SuggestResponse.self, from: complete(context))
    }

    /// JSON 모드로 받고 형식 검증은 앱이 한다 (SPEC 5.3: 구조화 출력 미지원 시 구현체가 검증 · 재시도).
    private func complete(_ context: ContextPackage) async throws -> String {
        guard !model.isEmpty else { throw ProviderError.missingModel }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": Prompt.system],
                ["role": "user", "content": Prompt.userMessage(for: context)],
            ],
            "response_format": ["type": "json_object"],
        ]
        let object = try await HTTP.post(
            URL(string: "https://api.openai.com/v1/chat/completions")!,
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: body
        )
        if let usage = object["usage"] as? [String: Any] {
            UsageMeter.record(TokenUsage(inputTokens: UsageMeter.int(usage["prompt_tokens"]), outputTokens: UsageMeter.int(usage["completion_tokens"])))
        }
        let message = (object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        guard let text = message?["content"] as? String, !text.isEmpty else { throw ProviderError.emptyResponse }
        return text
    }

    public static func models(apiKey: String) async throws -> [String] {
        let object = try await HTTP.get(URL(string: "https://api.openai.com/v1/models")!, headers: ["Authorization": "Bearer \(apiKey)"])
        return (object["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted()
    }
}
