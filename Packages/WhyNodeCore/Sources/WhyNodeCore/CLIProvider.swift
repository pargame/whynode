#if os(macOS)
import Foundation

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

    func arguments(for context: ContextPackage) throws -> [String] {
        let schema = Prompt.schema(for: context.kind)
        let message = Prompt.userMessage(for: context)
        let modelArgs = model.isEmpty ? [] : ["--model", model]
        switch kind {
        case .anthropic:
            return ["-p", "--output-format", "json", "--json-schema", schema, "--system-prompt", Prompt.system] + modelArgs + [message]
        case .google:
            // agy는 시스템 프롬프트 옵션이 없어 본문 앞에 붙인다.
            return ["--mode", "plan", "--output-format", "json", "--json-schema", schema] + modelArgs + ["-p=\(Prompt.system)\n\n\(message)"]
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
            throw ProviderError.cliFailed(object["result"] as? String ?? "알 수 없는 오류")
        }
        if let status = object["status"] as? String, status != "SUCCESS" {
            throw ProviderError.cliFailed(object["response"] as? String ?? status)
        }
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

    /// GUI 앱은 PATH가 짧으므로 흔한 설치 위치와 로그인 셸의 PATH에서 CLI를 찾는다.
    public static func locate(_ tool: String) -> URL? {
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
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

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
                    if finished.terminationStatus == 0 {
                        continuation.resume(returning: out)
                    } else {
                        let message = String(decoding: err.isEmpty ? out : err, as: UTF8.self)
                        continuation.resume(throwing: ProviderError.cliFailed(String(message.suffix(400))))
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: ProviderError.cliFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
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
