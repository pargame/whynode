import Foundation

public enum V1ImportError: Error, Equatable, LocalizedError {
    case notV1
    case noRoot

    public var errorDescription: String? {
        switch self {
        case .notV1: "WhyNode v1 파일이 아닙니다."
        case .noRoot: "루트 노드가 없는 v1 파일입니다."
        }
    }
}

/// 스킬이 만든 v1 파일(`version: "1.0.0"`)을 v2 문서로 변환한다 (SPEC 7.7). 원본은 수정하지 않는다.
public enum V1Import {
    public static let missingAnswerMessage = "답변 없음"

    struct File: Decodable {
        struct Project: Decodable {
            var id: String
            var title: String
            var createdAt: String
            var updatedAt: String
        }

        struct Node: Decodable {
            var id: String
            var parentId: String?
            var text: String
            var content: String?
            var state: String
        }

        var version: String
        var project: Project
        var nodes: [Node]
    }

    /// 변환된 문서와 새 문서의 기본 파일명(v1 `project.title`)을 돌려준다.
    public static func convert(_ data: Data) throws -> (map: MindMap, title: String) {
        let v1: File
        do {
            v1 = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw V1ImportError.notV1
        }
        guard v1.version.hasPrefix("1.") else { throw V1ImportError.notV1 }

        let projectCreated = Timestamp.truncated(Timestamp.date(from: v1.project.createdAt) ?? Date())
        let projectUpdated = max(Timestamp.truncated(Timestamp.date(from: v1.project.updatedAt) ?? projectCreated), projectCreated)

        let real = v1.nodes.filter { $0.state != "candidate" }
        guard let v1Root = real.first(where: { $0.parentId == nil }) else { throw V1ImportError.noRoot }

        var idMap: [String: WID] = [:]
        for node in real { idMap[node.id] = WID() }

        var nodes: [Node] = []
        for (order, old) in real.enumerated() {
            // v1 배열 순서를 유지하도록 밀리초를 1씩 늘린다.
            let created = Date(milliseconds: projectCreated.milliseconds + Int64(order))
            let hasAnswer = !(old.content ?? "").isEmpty
            nodes.append(Node(
                id: idMap[old.id]!,
                parentId: old.id == v1Root.id ? nil : old.parentId.flatMap { idMap[$0] },
                question: old.text,
                answer: hasAnswer ? old.content : nil,
                summary: nil,
                status: hasAnswer ? .done : .error,
                error: hasAnswer ? nil : missingAnswerMessage,
                createdAt: created,
                updatedAt: max(projectUpdated, created)
            ))
        }

        for candidate in v1.nodes where candidate.state == "candidate" {
            guard let pid = candidate.parentId.flatMap({ idMap[$0] }),
                  let i = nodes.firstIndex(where: { $0.id == pid })
            else { continue }
            nodes[i].suggestions.append(Suggestion(text: candidate.text))
        }

        let lastUpdated = nodes.map(\.updatedAt).max() ?? projectUpdated
        let file = WhyNodeFile(
            project: ProjectMeta(createdAt: projectCreated, updatedAt: max(projectUpdated, lastUpdated)),
            rootId: idMap[v1Root.id]!,
            nodes: nodes
        )
        let repaired = Integrity.repair(file).file
        var map = MindMap(file: repaired)
        map.layoutUnplaced()
        return (map, v1.project.title)
    }
}

extension MindMap {
    /// 좌표가 모두 원점인 문서(v1 이전 직후)에 기본 배치를 적용한다.
    mutating func layoutUnplaced() {
        var positions: [WID: (x: Double, y: Double)] = [:]
        var queue = [rootId]
        var head = 0
        // 부모부터 차례로 자식 위치를 정한다. 이미 배치한 노드만 담은 지도를 키워 가며 형제 순서를 반영한다.
        var rebuilt = file
        rebuilt.nodes = [root]
        var placed = MindMap(file: rebuilt)
        while head < queue.count {
            let current = queue[head]
            head += 1
            for child in children(of: current) {
                let position = Layout.childPosition(in: placed, parentId: current)
                positions[child.id] = (position.x, position.y)
                var copy = child
                copy.position = position
                var f = placed.file
                f.nodes.append(copy)
                placed = MindMap(file: f)
                queue.append(child.id)
            }
        }
        applyLayout(positions)
    }
}
