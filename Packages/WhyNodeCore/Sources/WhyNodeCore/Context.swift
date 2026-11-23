import Foundation

/// AI에 보내는 맥락 패키지 (SPEC 6.1). 대화 기록 대신 매 요청마다 트리에서 다시 만든다.
public struct ContextPackage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case answer, suggest
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var question: String
        public var summary: String?
    }

    public struct Brief: Codable, Equatable, Sendable {
        public var id: String
        public var question: String
    }

    public var kind: Kind
    public var topic: String
    public var path: [Entry]
    public var parentAnswer: String?
    public var question: String
    public var answer: String?
    public var siblings: [Brief]?
    public var children: [Brief]?
    public var index: [Entry]
    public var exclude: [String]?
}

public enum ContextBuilder {
    /// `index`에 쓸 글자 수 예산. 토큰 수는 프로바이더마다 달라 글자 수로 근사한다.
    public static let defaultIndexBudget = 6_000
    public static let summaryFallbackLength = 60

    /// 노드 생성 · 답변 다시 받기 · 질문 수정 시의 `answer` 요청
    public static func answer(for id: WID, in map: MindMap, indexBudget: Int = defaultIndexBudget) -> ContextPackage? {
        guard let node = map[id] else { return nil }
        let parent = node.parentId.flatMap { map[$0] }
        return ContextPackage(
            kind: .answer,
            topic: id == map.rootId ? node.question : map.root.question,
            path: map.ancestors(of: id).map(entry),
            parentAnswer: parent?.answer,
            question: node.question,
            answer: nil,
            siblings: map.siblings(of: id).map(brief),
            children: nil,
            index: index(for: id, in: map, budget: indexBudget),
            exclude: nil
        )
    }

    /// 추가 질문 다시 받기 시의 `suggest` 요청
    public static func suggest(for id: WID, in map: MindMap, exclude: [String] = [], indexBudget: Int = defaultIndexBudget) -> ContextPackage? {
        guard let node = map[id] else { return nil }
        let previous = node.suggestions.map(\.text)
        return ContextPackage(
            kind: .suggest,
            topic: map.root.question,
            path: map.ancestors(of: id).map(entry),
            parentAnswer: nil,
            question: node.question,
            answer: node.answer,
            siblings: nil,
            children: map.children(of: id).map(brief),
            index: index(for: id, in: map, budget: indexBudget),
            exclude: Array(Set(previous + exclude)).sorted()
        )
    }

    /// 요약이 없으면 답변의 첫 문장(최대 60자)을 대신 쓴다.
    public static func summary(of node: Node) -> String? {
        if let summary = node.summary, !summary.isEmpty { return summary }
        guard let answer = node.answer.map(AnswerFormat.plainText)?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else { return nil }
        let sentence = answer.split(maxSplits: 1, whereSeparator: { ".!?。\n".contains($0) }).first.map(String.init) ?? answer
        return String(sentence.prefix(summaryFallbackLength))
    }

    private static func entry(_ node: Node) -> ContextPackage.Entry {
        .init(id: node.id.description, question: node.question, summary: summary(of: node))
    }

    private static func brief(_ node: Node) -> ContextPackage.Brief {
        .init(id: node.id.description, question: node.question)
    }

    /// 요청 대상을 뺀 전체 노드. 예산을 넘으면 경로 → 형제 · 자식 → 트리 거리 순으로 담고,
    /// 남은 노드는 질문만 남기거나 생략한다.
    static func index(for id: WID, in map: MindMap, budget: Int) -> [ContextPackage.Entry] {
        let distances = treeDistances(from: id, in: map)
        let pathIds = Set(map.ancestors(of: id).map(\.id))
        let nearIds = Set(map.siblings(of: id).map(\.id) + map.childIDs(of: id))
        let ordered = map.nodes
            .filter { $0.id != id && $0.status != .empty }
            .sorted { a, b in
                let ra = pathIds.contains(a.id) ? 0 : nearIds.contains(a.id) ? 1 : 2
                let rb = pathIds.contains(b.id) ? 0 : nearIds.contains(b.id) ? 1 : 2
                if ra != rb { return ra < rb }
                let da = distances[a.id] ?? .max, db = distances[b.id] ?? .max
                if da != db { return da < db }
                return (a.createdAt, a.id) < (b.createdAt, b.id)
            }
        var result: [ContextPackage.Entry] = []
        var used = 0
        for node in ordered {
            var item = entry(node)
            var cost = item.question.count + (item.summary?.count ?? 0)
            if used + cost > budget {
                item.summary = nil
                cost = item.question.count
                if used + cost > budget { break }
            }
            used += cost
            result.append(item)
        }
        return result
    }

    static func treeDistances(from id: WID, in map: MindMap) -> [WID: Int] {
        var distances: [WID: Int] = [id: 0]
        var queue = [id]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            var neighbors = map.childIDs(of: current)
            if let pid = map[current]?.parentId { neighbors.append(pid) }
            for next in neighbors where distances[next] == nil {
                distances[next] = distances[current]! + 1
                queue.append(next)
            }
        }
        return distances
    }
}
