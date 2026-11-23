import SwiftUI
import WhyNodeCore

/// 답변 본문을 WhyNode 서식 블록(SPEC 6.5)으로 그린다.
struct AnswerView: View {
    let markdown: String
    var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(AnswerFormat.blocks(from: markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    inline(text)
                case .bullets(let items):
                    list(items) { _ in "•" }
                case .steps(let items):
                    list(items) { "\($0 + 1)." }
                case .diagram(let rows):
                    diagram(rows)
                }
            }
        }
        .font(.scaled(.callout, scale))
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 굵게 · 기울임 · 인라인 코드만 직접 해석해 그린다 (한글 조사가 붙은 굵게도 인식).
    private func inline(_ text: String) -> some View {
        var attributed = AttributedString()
        for span in InlineMarkup.spans(text) {
            var piece = AttributedString(span.text)
            if span.code {
                piece.font = .scaled(.callout, scale, design: .monospaced)
                piece.backgroundColor = Color.secondary.opacity(0.14)
            } else if span.bold || span.italic {
                var font = Font.scaled(.callout, scale)
                if span.bold { font = font.bold() }
                if span.italic { font = font.italic() }
                piece.font = font
            }
            attributed += piece
        }
        return Text(attributed)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func list(_ items: [String], marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(marker(index))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    inline(item)
                }
            }
        }
    }

    /// 텍스트 다이어그램은 줄 구성을 지키도록 고정폭으로 그리고, 넓으면 가로로 스크롤한다.
    private func diagram(_ rows: [String]) -> some View {
        let text = Text(verbatim: rows.joined(separator: "\n"))
            .font(.scaled(.caption, scale, design: .monospaced))
            .fixedSize()
            .padding(8)
        return ViewThatFits(in: .horizontal) {
            text
            ScrollView(.horizontal, showsIndicators: false) { text }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
