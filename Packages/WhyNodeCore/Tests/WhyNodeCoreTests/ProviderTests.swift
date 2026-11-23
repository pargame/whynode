import Foundation
import Testing
@testable import WhyNodeCore

@Suite("AI 응답 해석")
struct ProviderParsingTests {
    @Test func 설명과_코드_블록이_섞여도_JSON을_찾는다() throws {
        let text = """
        다음과 같습니다.
        ```json
        {"suggestions": ["왜 {괄호}가 들어가도 될까?", "두 번째"]}
        ```
        """
        let value = try JSONExtract.decode(SuggestResponse.self, from: text)
        #expect(value.suggestions == ["왜 {괄호}가 들어가도 될까?", "두 번째"])
    }

    @Test func refs가_없어도_답변을_읽는다() throws {
        let value = try JSONExtract.decode(AnswerResponse.self, from: #"{"answer":"a","summary":"s","suggestions":["q"]}"#)
        #expect(value.refs.isEmpty)
    }

    #if os(macOS)
    @Test func claude_CLI_결과는_structured_output을_쓴다() throws {
        let output = #"{"type":"result","is_error":false,"result":"{\"suggestions\":[\"x\"]}","structured_output":{"suggestions":["왜 하늘은 파랄까?"]}}"#
        let value = try CLIProvider.extract(SuggestResponse.self, from: Data(output.utf8), usable: { !$0.suggestions.isEmpty })
        #expect(value.suggestions == ["왜 하늘은 파랄까?"])
    }

    @Test func agy_CLI_결과의_structured_output이_비면_본문에서_찾는다() throws {
        let output = #"{"status":"SUCCESS","response":"{\"topic\":\"무지개\"}\n{\"suggestions\":[\"왜 둥글까?\"]}\n","structured_output":{"suggestions":[]}}"#
        let value = try CLIProvider.extract(SuggestResponse.self, from: Data(output.utf8), usable: { !$0.suggestions.isEmpty })
        #expect(value.suggestions == ["왜 둥글까?"])
    }

    @Test func CLI_오류_결과는_실패로_본다() {
        let output = #"{"type":"result","is_error":true,"result":"로그인이 필요합니다"}"#
        #expect(throws: ProviderError.cliFailed("로그인이 필요합니다")) {
            try CLIProvider.extract(SuggestResponse.self, from: Data(output.utf8), usable: { _ in true })
        }
    }

    @Test func agy_모델_목록을_읽는다() {
        let text = "Fetching available models...\ngemini-4-neon-medium\tGemini 4 Neon (Medium)\nclaude-opus-5-5-low\tClaude Opus 5.5 (Low)\n"
        let models = CLIProvider.parseModelList(text)
        #expect(models.map(\.id) == ["gemini-4-neon-medium", "claude-opus-5-5-low"])
        #expect(models.first?.name == "Gemini 4 Neon (Medium)")
    }

    @Test func claude_인자는_도구와_설정_로드를_끈다() throws {
        let provider = CLIProvider(kind: .anthropic, executable: URL(fileURLWithPath: "/usr/bin/true"), model: "haiku")
        let args = try provider.arguments(for: ConnectionTest.context)
        #expect(args.contains("--tools"))
        #expect(args.contains("--setting-sources"))
        #expect(args.contains("--no-session-persistence"))
        #expect(!args.contains("--effort"))
        #expect(args.contains("haiku"))
    }

    @Test func agy_인자는_스킬_확장을_끄고_plan_모드를_쓰지_않는다() throws {
        let provider = CLIProvider(kind: .google, executable: URL(fileURLWithPath: "/usr/bin/true"))
        let args = try provider.arguments(for: ConnectionTest.context)
        #expect(args.contains("--disable-slash-commands"))
        #expect(!args.contains("--mode"))
    }

    /// 실제 CLI 호출. `WHYNODE_LIVE_CLI=agy` 또는 `claude`로 켤 때만 실행한다.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WHYNODE_LIVE_CLI"] != nil))
    func 실제_CLI_연결_테스트() async throws {
        let tool = ProcessInfo.processInfo.environment["WHYNODE_LIVE_CLI"]!
        let kind = try #require(ProviderKind.allCases.first { $0.cliTool == tool })
        let executable = try #require(CLIProvider.locate(tool))
        let suggestions = try await ConnectionTest.run(CLIProvider(kind: kind, executable: executable))
        print("LIVE", tool, suggestions)
        #expect(!suggestions.isEmpty)
    }
    #endif
}

#if os(macOS)
@Suite("agy 상시 연결")
struct ACPTests {
    /// `WHYNODE_LIVE_ACP=1`일 때만 실제 `agy acp`로 두 번 연속 요청한다.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WHYNODE_LIVE_ACP"] != nil))
    func 상시_연결로_두_번_요청한다() async throws {
        let executable = try #require(CLIProvider.locate("agy"))
        let client = ACPClient(executable: executable)
        let started = ContinuousClock.now
        try await client.start()
        print("ACP 연결", ContinuousClock.now - started)
        let provider = ACPProvider(client: client, model: ProcessInfo.processInfo.environment["WHYNODE_LIVE_ACP_MODEL"] ?? "")
        for round in 1...2 {
            let begin = ContinuousClock.now
            let suggestions = try await ConnectionTest.run(provider)
            print("ACP 요청 \(round)", ContinuousClock.now - begin, await client.lastUsage ?? [:], suggestions)
            #expect(!suggestions.isEmpty)
        }
        await client.shutdown()
    }

    /// 답하지 않는 가짜 ACP 서버로 시간 초과가 실제로 대기를 끝내는지 확인한다.
    @Test func 응답이_없으면_시간_초과로_끝난다() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WhyNodeFakeACP-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-acp")
        // session/prompt만 무시하고 나머지 요청에는 세션 id로 답한다.
        try """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in *'"prompt":'*) continue ;; esac
          case "$line" in *'"id":'*) ;; *) continue ;; esac
          id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
          printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"s1"}}\\n' "$id"
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let client = ACPClient(executable: script)
        let started = ContinuousClock.now
        await #expect(throws: ProviderError.timeout) {
            try await client.ask("질문", model: "", timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        await client.shutdown()
    }
}
#endif
