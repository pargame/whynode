#if os(macOS)
import Foundation
import Testing
@testable import WhyNodeCore

/// 같은 주제를 한국어 · 영어로 루트 답변 요청해 토큰 사용량과 답변 언어를 비교한다.
/// `WHYNODE_LIVE_TOKENS=claude` 또는 `agy`일 때만 실행한다(실제 사용량 발생).
@Suite("실측 언어별 토큰")
struct LiveTokenTests {
    static let topics = [("ko", "양자역학"), ("en", "quantum mechanics")]

    static func rootContext(_ topic: String) -> ContextPackage {
        var map = MindMap.new()
        map.setRootQuestion(topic)
        return ContextBuilder.answer(for: map.rootId, in: map)!
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WHYNODE_LIVE_TOKENS"] != nil))
    func 실제_언어별_토큰() async throws {
        let tool = ProcessInfo.processInfo.environment["WHYNODE_LIVE_TOKENS"]!
        let executable = try #require(CLIProvider.locate(tool))
        if tool == "claude" {
            let provider = CLIProvider(kind: .anthropic, executable: executable, model: ProcessInfo.processInfo.environment["WHYNODE_LIVE_MODEL"] ?? "")
            for (lang, topic) in Self.topics {
                let output = try await CLIProcess.run(executable, arguments: provider.arguments(for: Self.rootContext(topic)))
                let object = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
                let usage = object["usage"] as? [String: Any] ?? [:]
                let answer = (object["structured_output"] as? [String: Any])?["answer"] as? String ?? ""
                print("TOKENS claude \(lang) input=\(usage["input_tokens"] ?? 0) cacheWrite=\(usage["cache_creation_input_tokens"] ?? 0) cacheRead=\(usage["cache_read_input_tokens"] ?? 0) output=\(usage["output_tokens"] ?? 0) cost=\(object["total_cost_usd"] ?? 0)")
                print("ANSWER claude \(lang): \(answer.prefix(120))")
            }
        } else {
            let client = ACPClient(executable: executable)
            let model = ProcessInfo.processInfo.environment["WHYNODE_LIVE_MODEL"] ?? ""
            for (lang, topic) in Self.topics {
                let text = try await client.ask(Prompt.userMessage(for: Self.rootContext(topic)), model: model, timeout: .seconds(180))
                print("TOKENS agy \(lang) \(await client.lastUsage ?? [:])")
                print("ANSWER agy \(lang): \(text.prefix(160))")
            }
            await client.shutdown()
        }
    }
}
#endif
