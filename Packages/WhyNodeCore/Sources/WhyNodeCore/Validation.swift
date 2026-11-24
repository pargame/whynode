import Foundation

/// AI 응답 원문 (SPEC 6.3). 참조 id는 AI가 쓴 문자열 그대로 받는다.
public struct AnswerResponse: Codable, Equatable, Sendable {
    public struct RawRef: Codable, Equatable, Sendable {
        public var nodeId: String
        public var reason: String

        public init(nodeId: String, reason: String) {
            self.nodeId = nodeId
            self.reason = reason
        }
    }

    public var answer: String
    public var summary: String
    public var suggestions: [String]
    public var refs: [RawRef]

    public init(answer: String, summary: String, suggestions: [String], refs: [RawRef] = []) {
        self.answer = answer
        self.summary = summary
        self.suggestions = suggestions
        self.refs = refs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answer = try c.decode(String.self, forKey: .answer)
        summary = try c.decode(String.self, forKey: .summary)
        suggestions = try c.decode([String].self, forKey: .suggestions)
        // 참조가 없으면 생략하는 모델이 있어 빈 배열로 받는다.
        refs = try c.decodeIfPresent([RawRef].self, forKey: .refs) ?? []
    }
}

public struct SuggestResponse: Codable, Equatable, Sendable {
    public var suggestions: [String]

    public init(suggestions: [String]) {
        self.suggestions = suggestions
    }
}

public struct ValidatedAnswer: Equatable, Sendable {
    public var answer: String
    public var summary: String
    public var suggestions: [String]
    public var refs: [NodeRef]
    /// 중복으로 걸러진 추가 질문. 부족할 때 `suggest` 재요청의 `exclude`로 쓴다.
    public var removed: [String]

    public init(answer: String, summary: String, suggestions: [String], refs: [NodeRef], removed: [String]) {
        self.answer = answer
        self.summary = summary
        self.suggestions = suggestions
        self.refs = refs
        self.removed = removed
    }

    /// 남은 추가 질문이 2개 미만이면 `suggest`를 1회 자동 요청한다 (SPEC 6.4-4).
    public var needsMoreSuggestions: Bool { suggestions.count < ResponseValidator.minimumSuggestions }
}

public enum ValidationError: Error, Equatable, LocalizedError {
    case emptyField(String)

    public var errorDescription: String? {
        switch self {
        case .emptyField(let name): L("The AI response's \(name) is empty.")
        }
    }
}

/// 앱 측 응답 검증 (SPEC 6.4)
public enum ResponseValidator {
    public static let minimumSuggestions = 2
    public static let defaultThreshold = 0.6

    public static func validate(
        _ response: AnswerResponse,
        for id: WID,
        in map: MindMap,
        threshold: Double = defaultThreshold
    ) throws -> ValidatedAnswer {
        let answer = response.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // 요약과 추가 질문은 한 줄로 쓰이므로 서식 기호를 걷어낸다 (SPEC 6.5).
        let summary = AnswerFormat.plainText(response.summary).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw ValidationError.emptyField("answer") }
        guard !summary.isEmpty else { throw ValidationError.emptyField("summary") }

        let (kept, removed) = dedupe(response.suggestions.map(AnswerFormat.plainText), against: existingQuestions(for: id, in: map), threshold: threshold)
        return ValidatedAnswer(answer: answer, summary: summary, suggestions: kept, refs: refs(response.refs, for: id, in: map), removed: removed)
    }

    public static func validate(
        _ response: SuggestResponse,
        for id: WID,
        in map: MindMap,
        threshold: Double = defaultThreshold
    ) -> (suggestions: [String], removed: [String]) {
        var existing = existingQuestions(for: id, in: map)
        // 다시 받기는 기존 미사용 질문을 교체하므로, 사용된 질문과만 겹치지 않으면 된다.
        existing.append(contentsOf: map[id]?.suggestions.filter { $0.usedBy != nil }.map(\.text) ?? [])
        return dedupe(response.suggestions.map(AnswerFormat.plainText), against: existing, threshold: threshold)
    }

    /// 존재하지 않거나 자기 자신 · 부모 · 직계 자식을 가리키는 참조와 중복 참조를 제거한다.
    static func refs(_ raw: [AnswerResponse.RawRef], for id: WID, in map: MindMap) -> [NodeRef] {
        var excluded: Set<WID> = [id]
        if let pid = map[id]?.parentId { excluded.insert(pid) }
        excluded.formUnion(map.childIDs(of: id))
        var seen = Set<WID>()
        return raw.compactMap { ref in
            guard let target = WID(string: ref.nodeId), map[target] != nil,
                  !excluded.contains(target), seen.insert(target).inserted
            else { return nil }
            return NodeRef(nodeId: target, reason: ref.reason)
        }
    }

    static func existingQuestions(for id: WID, in map: MindMap) -> [String] {
        map.nodes.filter { !$0.question.isEmpty }.map(\.question)
    }

    /// 표면 중복 제거. 의미 중복은 프롬프트가 담당하고 여기서는 거의 같은 문장만 거른다.
    static func dedupe(_ candidates: [String], against existing: [String], threshold: Double) -> ([String], [String]) {
        var references = existing.map(normalize)
        var kept: [String] = []
        var removed: [String] = []
        for candidate in candidates {
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let normalized = normalize(text)
            let duplicate = normalized.isEmpty || references.contains { other in
                other == normalized || jaccard(bigrams(other), bigrams(normalized)) >= threshold
            }
            if duplicate {
                removed.append(text)
            } else {
                kept.append(text)
                references.append(normalized)
            }
        }
        return (kept, removed)
    }

    static let stopwords = ["도대체", "과연", "그렇다면", "그러면", "그럼", "정말", "과연"]
    static let questionEndings = ["인가요", "일까요", "을까요", "할까요", "는가요", "나요", "까요", "는가", "을까", "일까", "할까", "인가", "까", "요"]

    static func normalize(_ text: String) -> String {
        var s = text.precomposedStringWithCompatibilityMapping.lowercased()
        s = String(s.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0) }.map(Character.init))
        for word in stopwords {
            s = s.replacingOccurrences(of: word, with: " ")
        }
        s = String(s.filter { !$0.isWhitespace })
        if let ending = questionEndings.first(where: { s.hasSuffix($0) && s.count > $0.count }) {
            s = String(s.dropLast(ending.count))
        }
        return s
    }

    static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count > 1 else { return chars.isEmpty ? [] : [String(chars)] }
        return Set((0..<chars.count - 1).map { String(chars[$0...$0 + 1]) })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 1 : Double(a.intersection(b).count) / Double(union)
    }
}
