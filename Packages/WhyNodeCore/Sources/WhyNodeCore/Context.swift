import Foundation

/// AI에 보내는 맥락 패키지 (SPEC 6.1). 대화 기록 대신 매 요청마다 트리에서 다시 만든다.
public struct ContextPackage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case answer, suggest, links
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var question: String
        public var summary: String?
        /// `links` 요청에서만 채운다. 부모 · 자식 쌍을 제안하지 않게 한다.
        public var parent: String?
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
    /// `links` 요청에서만 채운다. 이미 이어진 노드 쌍(짧은 id).
    public var existingLinks: [[String]]?
}

/// `links` 요청의 맥락과 짧은 id → 노드 id 대응표. UUID 대신 번호를 보내 토큰을 줄인다.
public struct LinksRequest: Sendable {
    public var context: ContextPackage
    public var ids: [String: WID]
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
            exclude: nil,
            existingLinks: nil
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
            exclude: Array(Set(previous + exclude)).sorted(),
            existingLinks: nil
        )
    }

    /// 참조선 다시 찾기의 `links` 요청 (SPEC 5.3). 맵 전체의 질문 · 요약을 만든 순서대로 담고,
    /// 예산을 넘으면 뒤쪽 노드는 질문만 남기거나 생략한다. 답변이 있는 노드가 2개 미만이면 nil.
    public static func links(in map: MindMap, budget: Int = defaultLinksBudget) -> LinksRequest? {
        let nodes = map.nodes
            .filter { $0.status == .done && !$0.question.isEmpty }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        guard nodes.count >= 2 else { return nil }
        var short: [WID: String] = [:]
        var ids: [String: WID] = [:]
        for (i, node) in nodes.enumerated() {
            let key = "n\(i + 1)"
            short[node.id] = key
            ids[key] = node.id
        }
        var index: [ContextPackage.Entry] = []
        var used = 0
        for node in nodes {
            var item = ContextPackage.Entry(id: short[node.id]!, question: node.question, summary: summary(of: node), parent: node.parentId.flatMap { short[$0] })
            var cost = item.question.count + (item.summary?.count ?? 0)
            if used + cost > budget {
                item.summary = nil
                cost = item.question.count
                if used + cost > budget { break }
            }
            used += cost
            index.append(item)
        }
        var existing: [[String]] = []
        for node in nodes {
            for ref in node.refs {
                if let a = short[node.id], let b = short[ref.nodeId] { existing.append([a, b]) }
            }
        }
        let context = ContextPackage(
            kind: .links,
            topic: map.root.question,
            path: [],
            parentAnswer: nil,
            question: map.root.question,
            answer: nil,
            siblings: nil,
            children: nil,
            index: index,
            exclude: nil,
            existingLinks: existing.isEmpty ? nil : existing
        )
        return LinksRequest(context: context, ids: ids)
    }

    /// `links` 요청의 글자 수 예산. 맵 전체를 보므로 `index`보다 넉넉하다.
    public static let defaultLinksBudget = 24_000

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
