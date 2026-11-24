import Foundation
import Synchronization

/// 모델 선택지 (ID와 화면 표시명)
public struct ModelOption: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

#if os(macOS)

/// ③ 공식 CLI 연동. 사용자의 로컬 CLI를 자식 프로세스로 실행하며 인증 정보는 다루지 않는다 (SPEC 5.1).
public struct CLIProvider: AIProvider {
    public let kind: ProviderKind
    public let executable: URL
    public let model: String
    public let connection = Connection.cli
    public let capabilities = ProviderCapabilities(structuredOutput: true, maxConcurrentRequests: 2)
    public var timeout: Duration = .seconds(180)

    public var name: String { kind.rawValue }

    public init(kind: ProviderKind, executable: URL, model: String = "") {
        self.kind = kind
        self.executable = executable
        self.model = model
    }

    public func answer(_ context: ContextPackage) async throws -> AnswerResponse {
        let output = try await run(context)
        return try Self.extract(AnswerResponse.self, from: output, usable: \.isUsable)
    }

    public func suggest(_ context: ContextPackage) async throws -> SuggestResponse {
        let output = try await run(context)
        return try Self.extract(SuggestResponse.self, from: output, usable: { !$0.suggestions.isEmpty })
    }

    public func links(_ context: ContextPackage) async throws -> LinksResponse {
        let output = try await run(context)
        return try Self.extract(LinksResponse.self, from: output, usable: { _ in true })
    }

    func arguments(for context: ContextPackage) throws -> [String] {
        let schema = Prompt.schema(for: context.kind)
        let message = Prompt.userMessage(for: context)
        let modelArgs = model.isEmpty ? [] : ["--model", model]
        // 질의응답에 필요 없는 도구 · 스킬 · 설정 로드를 꺼서 호출당 토큰과 지연을 줄인다.
        switch kind {
        case .anthropic:
            let lean = ["--tools", "", "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands", "--no-session-persistence"]
            return ["-p", "--output-format", "json", "--json-schema", schema, "--system-prompt", Prompt.system] + lean + modelArgs + [message]
        case .google:
            // agy는 시스템 프롬프트 옵션이 없어 본문 앞에 붙인다.
            return ["--disable-slash-commands", "--output-format", "json", "--json-schema", schema] + modelArgs + ["-p=\(Prompt.system)\n\n\(message)"]
        case .openai:
            throw ProviderError.notSupported(kind.cliDisplayName)
        }
    }

    /// CLI의 JSON 결과에서 `structured_output`을 먼저 쓰고, 비어 있으면 본문(`result` · `response`)에서 찾는다.
    static func extract<T: Decodable>(_ type: T.Type, from output: Data, usable: (T) -> Bool) throws -> T {
        guard let object = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any] else {
            throw ProviderError.unreadableResponse(String(decoding: output.prefix(200), as: UTF8.self))
        }
        if object["is_error"] as? Bool == true {
            throw ProviderError.cliFailed(object["result"] as? String ?? L("Unknown error"))
        }
        if let status = object["status"] as? String, status != "SUCCESS" {
            throw ProviderError.cliFailed(object["response"] as? String ?? status)
        }
        UsageMeter.record(usage(from: object))
        if let structured = object["structured_output"],
           let data = try? JSONSerialization.data(withJSONObject: structured),
           let value = try? JSONDecoder().decode(T.self, from: data), usable(value) {
            return value
        }
        let text = (object["result"] as? String) ?? (object["response"] as? String) ?? ""
        for candidate in JSONExtract.objects(in: text).reversed() {
            if let value = try? JSONDecoder().decode(T.self, from: Data(candidate.utf8)), usable(value) {
                return value
            }
        }
        throw ProviderError.unreadableResponse(String(text.prefix(200)))
    }

    /// claude `-p --output-format json`의 `usage` · `total_cost_usd`. 입력은 캐시 읽기 · 쓰기를 더한다.
    static func usage(from object: [String: Any]) -> TokenUsage? {
        guard let usage = object["usage"] as? [String: Any] else { return nil }
        let input = UsageMeter.int(usage["input_tokens"]) + UsageMeter.int(usage["cache_creation_input_tokens"]) + UsageMeter.int(usage["cache_read_input_tokens"])
        return TokenUsage(inputTokens: input, outputTokens: UsageMeter.int(usage["output_tokens"]), costUSD: (object["total_cost_usd"] as? Double) ?? 0)
    }

    private func run(_ context: ContextPackage) async throws -> Data {
        let arguments = try arguments(for: context)
        let executable = executable
        let timeout = timeout
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await CLIProcess.run(executable, arguments: arguments) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProviderError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// CLI가 고를 수 있는 모델. agy는 `agy models` 목록을, claude는 공식 별칭을 쓴다.
    public static func models(kind: ProviderKind, executable: URL) async throws -> [ModelOption] {
        switch kind {
        case .anthropic:
            return [
                ModelOption(id: "haiku", name: L("Haiku (fastest, cheapest)")),
                ModelOption(id: "sonnet", name: L("Sonnet (balanced)")),
                ModelOption(id: "opus", name: L("Opus (most capable)")),
            ]
        case .google:
            let output = try await CLIProcess.run(executable, arguments: ["models"])
            return parseModelList(String(decoding: output, as: UTF8.self))
        case .openai:
            throw ProviderError.notSupported(kind.cliDisplayName)
        }
    }

    /// `id<TAB>표시명` 줄 목록을 읽는다. 안내 문구처럼 탭이 없는 줄은 건너뛴다.
    static func parseModelList(_ text: String) -> [ModelOption] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[0].contains(" ") else { return nil }
            return ModelOption(id: parts[0], name: parts[1])
        }
    }

    /// 찾은 CLI 위치. 로그인 셸 실행은 수백 ms가 걸려 화면을 멈추므로 한 번만 찾는다.
    /// 못 찾은 결과는 남기지 않아, 설치한 뒤 다시 시도하면 새로 찾는다.
    private static let located = Mutex<[String: URL]>([:])

    /// GUI 앱은 PATH가 짧으므로 흔한 설치 위치와 로그인 셸의 PATH에서 CLI를 찾는다.
    public static func locate(_ tool: String) -> URL? {
        if let cached = located.withLock({ $0[tool] }) {
            if FileManager.default.isExecutableFile(atPath: cached.path) { return cached }
            located.withLock { $0[tool] = nil }
        }
        guard let url = search(tool) else { return nil }
        located.withLock { $0[tool] = url }
        return url
    }

    private static func search(_ tool: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/bin"]
        for dir in candidates {
            let path = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v \(tool)"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard shell.terminationStatus == 0, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

/// 자식 프로세스 실행. 작업 취소 시 프로세스를 종료한다.
enum CLIProcess {
    static func run(_ executable: URL, arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // CLI가 프로젝트 파일을 읽지 않도록 빈 임시 폴더에서 실행한다.
        let workdir = FileManager.default.temporaryDirectory.appendingPathComponent("WhyNodeCLI", isDirectory: true)
        try? FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        process.currentDirectoryURL = workdir
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        // 요청마다 내용이 달라 캐시를 다시 읽는 일이 없으므로, 기본 1시간 캐시 쓰기(입력 단가 2배)를 끈다.
        // 같은 요청 실측 비용이 약 25% 줄었다. agy는 이 변수를 쓰지 않는다.
        environment["DISABLE_PROMPT_CACHING"] = "1"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let cancel = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let output = OutputBuffer()
                stdout.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData, error: false) }
                stderr.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData, error: true) }
                process.terminationHandler = { finished in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    output.append(stdout.fileHandleForReading.readDataToEndOfFile(), error: false)
                    output.append(stderr.fileHandleForReading.readDataToEndOfFile(), error: true)
                    let (out, err) = output.snapshot()
                    if cancel.isSet {
                        // 취소로 종료한 경우는 실패가 아니라 취소로 알린다.
                        continuation.resume(throwing: CancellationError())
                    } else if finished.terminationStatus == 0 {
                        continuation.resume(returning: out)
                    } else {
                        let message = String(decoding: err.isEmpty ? out : err, as: UTF8.self)
                        continuation.resume(throwing: ProviderError.cliFailed(String(message.suffix(400))))
                    }
                }
                // 이미 취소됐으면 실행하지 않는다. 실행과 취소 표시는 같은 잠금 안에서 순서를 정해, 취소된 프로세스가 끝까지 도는 일을 막는다.
                let started = cancel.runUnlessCancelled {
                    do {
                        try process.run()
                        return nil
                    } catch {
                        return error
                    }
                }
                switch started {
                case .cancelled:
                    process.terminationHandler = nil
                    continuation.resume(throwing: CancellationError())
                case .failed(let error):
                    process.terminationHandler = nil
                    continuation.resume(throwing: ProviderError.cliFailed(error.localizedDescription))
                case .started:
                    break
                }
            }
        } onCancel: {
            cancel.set { if process.isRunning { process.terminate() } }
        }
    }
}

/// 프로세스 실행과 취소의 순서를 맞추는 잠금 플래그
private final class CancelFlag: @unchecked Sendable {
    enum Start { case started, cancelled, failed(Error) }

    private let lock = NSLock()
    private var cancelled = false

    var isSet: Bool { lock.withLock { cancelled } }

    /// 취소 표시를 하고, 이미 실행 중이면 `stop`을 부른다.
    func set(_ stop: () -> Void) {
        lock.withLock {
            cancelled = true
            stop()
        }
    }

    func runUnlessCancelled(_ run: () -> Error?) -> Start {
        lock.withLock {
            if cancelled { return .cancelled }
            if let error = run() { return .failed(error) }
            return .started
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func append(_ data: Data, error: Bool) {
        lock.withLock {
            if error { err.append(data) } else { out.append(data) }
        }
    }

    func snapshot() -> (Data, Data) {
        lock.withLock { (out, err) }
    }
}
#endif
