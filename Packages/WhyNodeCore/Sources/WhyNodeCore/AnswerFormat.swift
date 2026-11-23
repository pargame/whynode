import Foundation

/// WhyNode 답변 서식 (SPEC 6.5). 노드 안에서 잘 보이는 최소한의 마크다운만 블록으로 정리한다.
/// AI가 규칙을 어겨도 화면이 깨지지 않도록, 허용하지 않는 문법은 여기서 일반 텍스트로 바꾼다.
public enum AnswerBlock: Equatable, Sendable {
    /// 인라인 마크다운(굵게 · 기울임 · 인라인 코드)을 담은 문단
    case paragraph(String)
    case bullets([String])
    case steps([String])
    /// 고정폭 텍스트 다이어그램. 줄 구성을 그대로 보여준다.
    case diagram([String])
}

public enum AnswerFormat {
    public static let maxParagraphs = 2
    public static let maxListItems = 5
    public static let maxDiagramLines = 10

    public static func blocks(from markdown: String) -> [AnswerBlock] {
        var raw = parse(markdown)
        raw = limitLists(raw)
        raw = limitDiagrams(raw)
        raw = limitParagraphs(raw)
        return raw
    }

    /// 요약처럼 한 줄로 쓰는 곳에서는 서식 기호를 모두 걷어낸다.
    public static func plainText(_ markdown: String) -> String {
        blocks(from: markdown).map { block -> String in
            switch block {
            case .paragraph(let text): stripInline(text)
            case .bullets(let items), .steps(let items): items.map(stripInline).joined(separator: ", ")
            case .diagram: ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    // 파싱

    private static func parse(_ markdown: String) -> [AnswerBlock] {
        var blocks: [AnswerBlock] = []
        var paragraph: [String] = []
        var list: (ordered: Bool, items: [String])?
        var fence: [String]?

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }
        func flushList() {
            if let list, !list.items.isEmpty {
                blocks.append(list.ordered ? .steps(list.items) : .bullets(list.items))
            }
            list = nil
        }

        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // 코드 블록은 언어와 상관없이 고정폭 다이어그램으로 보여준다.
            if trimmed.hasPrefix("```") {
                if let current = fence {
                    blocks.append(.diagram(trimTrailingEmpty(current)))
                    fence = nil
                } else {
                    flushParagraph(); flushList()
                    fence = []
                }
                continue
            }
            if fence != nil {
                fence!.append(rawLine.replacingOccurrences(of: "\t", with: "    "))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph(); flushList()
                continue
            }

            // 표는 정렬 구분선을 빼고 고정폭으로 보여준다.
            if trimmed.hasPrefix("|") {
                flushParagraph(); flushList()
                if trimmed.allSatisfy({ "|-: ".contains($0) }) { continue }
                if case .diagram(var rows)? = blocks.last {
                    rows.append(trimmed)
                    blocks[blocks.count - 1] = .diagram(rows)
                } else {
                    blocks.append(.diagram([trimmed]))
                }
                continue
            }

            if let item = listItem(trimmed) {
                flushParagraph()
                if list == nil || list!.ordered != item.ordered {
                    flushList()
                    list = (item.ordered, [])
                }
                list!.items.append(cleanInline(item.text))
                continue
            }

            flushList()
            paragraph.append(cleanInline(stripBlockMarkers(trimmed)))
        }
        if let fence { blocks.append(.diagram(trimTrailingEmpty(fence))) }
        flushParagraph(); flushList()
        return blocks.filter { block in
            if case .diagram(let rows) = block { return !rows.isEmpty }
            return true
        }
    }

    private static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return (false, String(line.dropFirst(marker.count)))
        }
        if let match = line.firstMatch(of: /^\d{1,2}[.)]\s+(.+)$/) {
            return (true, String(match.output.1))
        }
        return nil
    }

    /// 제목 · 인용 표시는 떼고 내용만 남긴다.
    private static func stripBlockMarkers(_ line: String) -> String {
        var s = line
        if let match = s.firstMatch(of: /^#{1,6}\s+(.+)$/) { s = String(match.output.1) }
        while s.hasPrefix(">") { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return s
    }

    /// 링크 · 이미지 · HTML · LaTeX를 화면에 맞는 표기로 바꾼다.
    static func cleanInline(_ text: String) -> String {
        var s = text
        s = s.replacing(/!\[[^\]]*\]\([^)]*\)/) { _ in "" }
        s = s.replacing(/\[([^\]]+)\]\([^)]*\)/) { "\($0.output.1)" }
        s = s.replacing(/<[^>]+>/) { _ in "" }
        s = s.replacing(/\$\$([^$]+)\$\$/) { "`\($0.output.1.trimmingCharacters(in: .whitespaces))`" }
        s = s.replacing(/\$([^$\n]+)\$/) { "`\($0.output.1.trimmingCharacters(in: .whitespaces))`" }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func stripInline(_ text: String) -> String {
        InlineMarkup.spans(text).map(\.text).joined()
    }

    private static func trimTrailingEmpty(_ rows: [String]) -> [String] {
        var rows = rows
        while let first = rows.first, first.trimmingCharacters(in: .whitespaces).isEmpty { rows.removeFirst() }
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty { rows.removeLast() }
        return rows
    }

    // 분량 제한

    /// 목록은 하나만 두고 항목 수를 제한한다. 넘친 항목과 두 번째 목록은 문단으로 이어 붙인다.
    private static func limitLists(_ blocks: [AnswerBlock]) -> [AnswerBlock] {
        var seenList = false
        return blocks.map { block in
            switch block {
            case .bullets(let items), .steps(let items):
                if seenList { return .paragraph(items.joined(separator: " · ")) }
                seenList = true
                guard items.count > maxListItems else { return block }
                var kept = Array(items.prefix(maxListItems))
                kept[maxListItems - 1] += ", " + items.dropFirst(maxListItems).joined(separator: ", ")
                if case .steps = block { return .steps(kept) }
                return .bullets(kept)
            default:
                return block
            }
        }
    }

    /// 다이어그램은 하나만 두고 줄 수를 제한한다.
    private static func limitDiagrams(_ blocks: [AnswerBlock]) -> [AnswerBlock] {
        var seenDiagram = false
        return blocks.compactMap { block in
            guard case .diagram(let rows) = block else { return block }
            if seenDiagram { return nil }
            seenDiagram = true
            return .diagram(Array(rows.prefix(maxDiagramLines)))
        }
    }

    /// 문단이 많으면 구조만 커지므로, 넘친 문단은 마지막 허용 문단에 이어 붙인다.
    private static func limitParagraphs(_ blocks: [AnswerBlock]) -> [AnswerBlock] {
        var result: [AnswerBlock] = []
        var count = 0
        var lastParagraphIndex: Int?
        for block in blocks {
            guard case .paragraph(let text) = block else {
                result.append(block)
                continue
            }
            count += 1
            if count <= maxParagraphs {
                result.append(block)
                lastParagraphIndex = result.count - 1
            } else if let i = lastParagraphIndex, case .paragraph(let previous) = result[i] {
                result[i] = .paragraph(previous + " " + text)
            }
        }
        return result
    }
}

/// 인라인 서식 조각. 표준 마크다운은 `**용어(ISN)**를`처럼 닫는 기호 뒤에 한글 조사가 붙으면
/// 굵게를 인식하지 못하므로, WhyNode가 쓰는 세 가지(굵게 · 기울임 · 인라인 코드)는 직접 해석한다.
public struct InlineSpan: Equatable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false

    public init(text: String, bold: Bool = false, italic: Bool = false, code: Bool = false) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
    }
}

public enum InlineMarkup {
    public static func spans(_ text: String) -> [InlineSpan] {
        var spans: [InlineSpan] = []
        var buffer = ""
        var bold = false
        var italic = false
        var rest = Substring(text)

        func flush() {
            if !buffer.isEmpty { spans.append(InlineSpan(text: buffer, bold: bold, italic: italic)) }
            buffer = ""
        }

        while let ch = rest.first {
            if ch == "`", let end = rest.dropFirst().firstIndex(of: "`") {
                flush()
                spans.append(InlineSpan(text: String(rest[rest.index(after: rest.startIndex)..<end]), bold: bold, italic: italic, code: true))
                rest = rest[rest.index(after: end)...]
            } else if rest.hasPrefix("**"), bold || rest.dropFirst(2).contains("**") {
                flush()
                bold.toggle()
                rest = rest.dropFirst(2)
            } else if ch == "*", italic || closesItalic(rest.dropFirst()) {
                flush()
                italic.toggle()
                rest = rest.dropFirst()
            } else {
                buffer.append(ch)
                rest = rest.dropFirst()
            }
        }
        flush()
        return merge(spans)
    }

    /// 짝이 되는 단일 `*`가 뒤에 있어야 기울임으로 본다. `2 * 3` 같은 곱셈 기호는 그대로 둔다.
    private static func closesItalic(_ rest: Substring) -> Bool {
        guard let first = rest.first, !first.isWhitespace else { return false }
        var index = rest.startIndex
        while index < rest.endIndex {
            if rest[index] == "*" {
                let next = rest.index(after: index)
                let doubled = next < rest.endIndex && rest[next] == "*"
                if !doubled { return index > rest.startIndex && !rest[rest.index(before: index)].isWhitespace }
                index = rest.index(after: next)
                continue
            }
            index = rest.index(after: index)
        }
        return false
    }

    private static func merge(_ spans: [InlineSpan]) -> [InlineSpan] {
        var result: [InlineSpan] = []
        for span in spans {
            if var last = result.last, last.bold == span.bold, last.italic == span.italic, last.code == span.code, !span.code {
                last.text += span.text
                result[result.count - 1] = last
            } else {
                result.append(span)
            }
        }
        return result
    }
}
