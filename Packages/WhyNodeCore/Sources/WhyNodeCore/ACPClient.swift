#if os(macOS)
import Foundation

/// `agy acp` 상시 연결. 앱 실행 동안 프로세스 하나를 유지하고, 노드 요청마다 새 세션을 열어
/// 대화가 쌓이지 않게 한다 (Agent Client Protocol, JSON-RPC over stdio).
public actor ACPClient {
    public nonisolated let executable: URL
    private var process: Process?
    private var stdin: FileHandle?
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var sessionText: [String: String] = [:]
    private var starting: Task<Void, Error>?

    public init(executable: URL) {
        self.executable = executable
    }

    /// 미리 연결해 두면 첫 요청의 대기 시간이 줄어든다.
    public func start() async throws {
        if process?.isRunning == true { return }
        if let starting { return try await starting.value }
        let task = Task { try await launch() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    /// 새 세션에서 질문 하나를 보내고 답변 본문을 돌려준 뒤 세션을 닫는다.
    public func ask(_ text: String, model: String, timeout: Duration) async throws -> String {
        try await start()
        let session = try await request("session/new", ["cwd": Self.workdir.path, "mcpServers": [Any]()])
        guard let sessionId = (try? JSONSerialization.jsonObject(with: session) as? [String: Any])?["sessionId"] as? String else {
            throw ProviderError.unreadableResponse("ACP 세션을 만들지 못했습니다.")
        }
        defer { Task { await self.close(sessionId) } }
        if !model.isEmpty {
            _ = try? await request("session/set_model", ["sessionId": sessionId, "modelId": model])
        }
        sessionText[sessionId] = ""
        do {
            _ = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await self.prompt(sessionId: sessionId, text: text) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ProviderError.timeout
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch {
            notify("session/cancel", ["sessionId": sessionId])
            throw error
        }
        return sessionText.removeValue(forKey: sessionId) ?? ""
    }

    private func prompt(sessionId: String, text: String) async throws -> Data {
        try await request("session/prompt", ["sessionId": sessionId, "prompt": [["type": "text", "text": text]]])
    }

    public func shutdown() {
        process?.terminate()
        reset(ProviderError.cliFailed("ACP 연결을 종료했습니다."))
    }

    // 연결

    static var workdir: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WhyNodeCLI", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func launch() async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["acp", "--disable-telemetry"]
        process.currentDirectoryURL = Self.workdir
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { await self?.reset(ProviderError.cliFailed("agy ACP 프로세스가 종료됐습니다.")) }
        }
        do {
            try process.run()
        } catch {
            throw ProviderError.cliFailed(error.localizedDescription)
        }
        self.process = process
        self.stdin = input.fileHandleForWriting

        let reader = output.fileHandleForReading
        Task { [weak self] in
            do {
                for try await line in reader.bytes.lines {
                    await self?.handle(line)
                }
            } catch {}
        }

        _ = try await request("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
        ])
    }

    private func reset(_ error: Error) {
        process = nil
        stdin = nil
        let waiting = pending
        pending = [:]
        sessionText = [:]
        waiting.values.forEach { $0.resume(throwing: error) }
    }

    private func close(_ sessionId: String) async {
        sessionText[sessionId] = nil
        _ = try? await request("session/close", ["sessionId": sessionId])
    }

    // JSON-RPC

    private func request(_ method: String, _ params: [String: Any]) async throws -> Data {
        guard let stdin else { throw ProviderError.cliFailed("agy ACP에 연결되어 있지 않습니다.") }
        nextId += 1
        let id = nextId
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try stdin.write(contentsOf: data)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: ProviderError.cliFailed(error.localizedDescription))
            }
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? stdin?.write(contentsOf: data + Data("\n".utf8))
    }

    private func respond(_ id: Any, result: Any? = nil, error: [String: Any]? = nil) {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let error { message["error"] = error } else { message["result"] = result ?? NSNull() }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? stdin?.write(contentsOf: data + Data("\n".utf8))
    }

    private func handle(_ line: String) {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return }
        if let method = message["method"] as? String {
            if let id = message["id"] {
                // 질의응답에는 파일 · 터미널 · 권한이 필요 없으므로 에이전트의 요청은 모두 거절한다.
                if method == "session/request_permission" {
                    respond(id, result: ["outcome": ["outcome": "cancelled"]])
                } else {
                    respond(id, error: ["code": -32601, "message": "WhyNode는 \(method)를 지원하지 않습니다."])
                }
            } else if method == "session/update",
                      let params = message["params"] as? [String: Any],
                      let sessionId = params["sessionId"] as? String,
                      let update = params["update"] as? [String: Any],
                      update["sessionUpdate"] as? String == "agent_message_chunk",
                      let text = (update["content"] as? [String: Any])?["text"] as? String,
                      sessionText[sessionId] != nil {
                sessionText[sessionId, default: ""] += text
            }
            return
        }
        guard let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] as? [String: Any] {
            continuation.resume(throwing: ProviderError.cliFailed(error["message"] as? String ?? "ACP 오류"))
        } else {
            let result = message["result"] ?? NSNull()
            let data = (try? JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed)) ?? Data()
            continuation.resume(returning: data)
        }
    }
}

/// ③ agy 상시 연결 프로바이더
public struct ACPProvider: AIProvider {
    public let client: ACPClient
    public let model: String
    public let name = ProviderKind.google.rawValue
    public let connection = Connection.cli
    public let capabilities = ProviderCapabilities(structuredOutput: false, maxConcurrentRequests: 3)
    public var timeout: Duration = .seconds(180)

    public init(client: ACPClient, model: String = "") {
        self.client = client
        self.model = model
    }

    public func answer(_ context: ContextPackage) async throws -> AnswerResponse {
        let text = try await client.ask(Self.message(for: context), model: model, timeout: timeout)
        return try Self.pick(AnswerResponse.self, from: text, usable: \.isUsable)
    }

    public func suggest(_ context: ContextPackage) async throws -> SuggestResponse {
        let text = try await client.ask(Self.message(for: context), model: model, timeout: timeout)
        return try Self.pick(SuggestResponse.self, from: text, usable: { !$0.suggestions.isEmpty })
    }

    /// ACP에는 시스템 프롬프트 지정이 없어 본문 앞에 붙인다.
    static func message(for context: ContextPackage) -> String {
        "\(Prompt.system)\n\n\(Prompt.userMessage(for: context))"
    }

    static func pick<T: Decodable>(_ type: T.Type, from text: String, usable: (T) -> Bool) throws -> T {
        for candidate in JSONExtract.objects(in: text).reversed() {
            if let value = try? JSONDecoder().decode(T.self, from: Data(candidate.utf8)), usable(value) {
                return value
            }
        }
        throw ProviderError.unreadableResponse(String(text.prefix(200)))
    }
}
#endif
