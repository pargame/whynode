import Testing
@testable import WhyNodeCore

@Suite("답변 서식")
struct AnswerFormatTests {
    @Test func 문단_목록_다이어그램을_블록으로_나눈다() {
        let text = """
        **레이트레이싱**은 광선을 역추적합니다.

        - 1차 광선 발사
        - 충돌 검사
        - 그림자 광선

        ```diagram
        카메라 → 픽셀 → 물체
                         ↓
                       광원
        ```
        """
        #expect(AnswerFormat.blocks(from: text) == [
            .paragraph("**레이트레이싱**은 광선을 역추적합니다."),
            .bullets(["1차 광선 발사", "충돌 검사", "그림자 광선"]),
            .diagram(["카메라 → 픽셀 → 물체", "                 ↓", "               광원"]),
        ])
    }

    @Test func 문단이_세_개를_넘으면_두_번째에_이어_붙인다() {
        let blocks = AnswerFormat.blocks(from: "첫째.\n\n둘째.\n\n셋째.\n\n넷째.")
        #expect(blocks == [.paragraph("첫째."), .paragraph("둘째. 셋째. 넷째.")])
    }

    @Test func 목록은_하나만_두고_항목_수를_제한한다() {
        let text = "1. a\n2. b\n3. c\n4. d\n5. e\n6. f\n7. g\n\n- x\n- y"
        #expect(AnswerFormat.blocks(from: text) == [
            .steps(["a", "b", "c", "d", "e, f, g"]),
            .paragraph("x · y"),
        ])
    }

    @Test func 금지_문법은_일반_텍스트로_바꾼다() {
        let text = "## 제목\n> 인용문\n[링크](https://x.y) ![그림](a.png) <b>굵게</b> 그리고 $E = mc^2$"
        #expect(AnswerFormat.blocks(from: text) == [
            .paragraph("제목 인용문 링크  굵게 그리고 `E = mc^2`"),
        ])
    }

    @Test func 표와_코드_블록은_고정폭으로_보여주고_다이어그램은_하나만_둔다() {
        let text = "| A | B |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet x = 1\n```"
        #expect(AnswerFormat.blocks(from: text) == [.diagram(["| A | B |", "| 1 | 2 |"])])
    }

    @Test func 닫히지_않은_코드_블록도_다이어그램으로_남긴다() {
        #expect(AnswerFormat.blocks(from: "설명\n```\nA → B") == [.paragraph("설명"), .diagram(["A → B"])])
    }

    @Test func 요약용_일반_텍스트는_서식_기호를_걷어낸다() {
        #expect(AnswerFormat.plainText("**광선**을 `추적`하는 방식") == "광선을 추적하는 방식")
    }
}

#if os(macOS)
import Foundation

/// `WHYNODE_LIVE_ANSWER=claude`(또는 agy)일 때만 실제 AI 답변이 서식 규칙을 따르는지 출력해 본다.
@Suite("답변 서식 실측")
struct LiveAnswerFormatTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WHYNODE_LIVE_ANSWER"] != nil))
    func 실제_답변_서식() async throws {
        let tool = ProcessInfo.processInfo.environment["WHYNODE_LIVE_ANSWER"]!
        let kind = try #require(ProviderKind.allCases.first { $0.cliTool == tool })
        let executable = try #require(CLIProvider.locate(tool))
        let client = ACPClient(executable: executable)
        let provider: any AIProvider = kind == .google
            ? ACPProvider(client: client, model: ProcessInfo.processInfo.environment["WHYNODE_LIVE_ACP_MODEL"] ?? "gemini-3.8-flash-low")
            : CLIProvider(kind: kind, executable: executable, model: "haiku")
        var map = MindMap.new()
        map.setRootQuestion("TCP 3-way handshake")
        let context = try #require(ContextBuilder.answer(for: map.rootId, in: map))
        let response = try await provider.answer(context)
        print("RAW\n\(response.answer)\nBLOCKS")
        for block in AnswerFormat.blocks(from: response.answer) { print(block) }
        print("SUMMARY", response.summary, "SUGGESTIONS", response.suggestions)
        if kind == .google { print("USAGE", await client.lastUsage ?? [:]) }
    }
}
#endif

@Suite("인라인 서식")
struct InlineMarkupTests {
    @Test func 닫는_굵게_뒤에_한글_조사가_붙어도_굵게로_본다() {
        #expect(InlineMarkup.spans("**초기 순서 번호(ISN)**를 보낸다") == [
            InlineSpan(text: "초기 순서 번호(ISN)", bold: true),
            InlineSpan(text: "를 보낸다"),
        ])
    }

    @Test func 인라인_코드_안의_기호는_서식으로_보지_않는다() {
        #expect(InlineMarkup.spans("값은 `a**b` 이다") == [
            InlineSpan(text: "값은 "),
            InlineSpan(text: "a**b", code: true),
            InlineSpan(text: " 이다"),
        ])
    }

    @Test func 짝이_없는_별표와_곱셈_기호는_그대로_둔다() {
        #expect(InlineMarkup.spans("2 * 3 = 6, 별표**") == [InlineSpan(text: "2 * 3 = 6, 별표**")])
    }

    @Test func 기울임을_해석한다() {
        #expect(InlineMarkup.spans("*파장*별로") == [InlineSpan(text: "파장", italic: true), InlineSpan(text: "별로")])
    }
}
