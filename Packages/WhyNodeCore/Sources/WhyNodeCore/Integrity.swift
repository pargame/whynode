import Foundation

public enum IntegrityIssue: Equatable, Sendable {
    case duplicateNode(WID)
    case rootReassigned(WID)
    case rootCreated(WID)
    case orphanReattached(WID)
    case cycleBroken(WID)
    case danglingRefRemoved(node: WID, target: WID)
    case danglingUsedByCleared(node: WID, suggestion: WID)
    case interruptedRequest(WID)
    case textScaleClamped(WID)
}

/// 불러온 문서의 무결성 규칙을 검사하고 복구한다 (SPEC 7.5).
public enum Integrity {
    public static let interruptedMessage = "중단됨"

    public static func repair(_ input: WhyNodeFile) -> (file: WhyNodeFile, issues: [IntegrityIssue]) {
        var file = input
        var issues: [IntegrityIssue] = []

        var seen = Set<WID>()
        file.nodes = file.nodes.filter { node in
            if seen.insert(node.id).inserted { return true }
            issues.append(.duplicateNode(node.id))
            return false
        }

        // 1. 루트는 정확히 하나이며 rootId와 일치해야 한다.
        if let i = file.nodes.firstIndex(where: { $0.id == file.rootId }) {
            if file.nodes[i].parentId != nil {
                file.nodes[i].parentId = nil
                issues.append(.rootReassigned(file.rootId))
            }
        } else if let first = file.nodes.first(where: { $0.parentId == nil }) {
            file.rootId = first.id
            issues.append(.rootReassigned(first.id))
        } else {
            let now = file.project.createdAt
            let root = Node(parentId: nil, question: "", status: .empty, createdAt: now, updatedAt: now)
            file.nodes.insert(root, at: 0)
            file.rootId = root.id
            issues.append(.rootCreated(root.id))
        }

        // 2. 모든 부모가 존재하고 루트에 도달해야 한다. 위반 노드는 루트의 자식으로 옮긴다.
        let ids = Set(file.nodes.map(\.id))
        for i in file.nodes.indices where file.nodes[i].id != file.rootId {
            if let pid = file.nodes[i].parentId, ids.contains(pid) { continue }
            file.nodes[i].parentId = file.rootId
            issues.append(.orphanReattached(file.nodes[i].id))
        }
        var parentOf = Dictionary(uniqueKeysWithValues: file.nodes.map { ($0.id, $0.parentId) })
        for i in file.nodes.indices where file.nodes[i].id != file.rootId {
            var visited: Set<WID> = [file.nodes[i].id]
            var current = file.nodes[i].parentId
            while let pid = current, pid != file.rootId {
                if !visited.insert(pid).inserted {
                    file.nodes[i].parentId = file.rootId
                    parentOf[file.nodes[i].id] = file.rootId
                    issues.append(.cycleBroken(file.nodes[i].id))
                    break
                }
                current = parentOf[pid] ?? nil
            }
        }

        // 3. 존재하지 않는 노드를 가리키는 참조 · usedBy를 정리한다.
        for i in file.nodes.indices {
            let nodeId = file.nodes[i].id
            file.nodes[i].refs.removeAll { ref in
                guard ids.contains(ref.nodeId) else {
                    issues.append(.danglingRefRemoved(node: nodeId, target: ref.nodeId))
                    return true
                }
                return false
            }
            for j in file.nodes[i].suggestions.indices {
                if let used = file.nodes[i].suggestions[j].usedBy, !ids.contains(used) {
                    file.nodes[i].suggestions[j].usedBy = nil
                    issues.append(.danglingUsedByCleared(node: nodeId, suggestion: file.nodes[i].suggestions[j].id))
                }
            }
        }

        // 4. 대기 상태로 저장된 노드는 이전 실행이 중단된 것이다.
        for i in file.nodes.indices where file.nodes[i].status == .pending {
            file.nodes[i].status = .error
            file.nodes[i].error = interruptedMessage
            issues.append(.interruptedRequest(file.nodes[i].id))
        }

        // 5. 글자 크기 배율은 허용 범위 안이어야 한다.
        for i in file.nodes.indices {
            let clamped = Node.clampedTextScale(file.nodes[i].textScale)
            if clamped != file.nodes[i].textScale {
                file.nodes[i].textScale = clamped
                issues.append(.textScaleClamped(file.nodes[i].id))
            }
        }

        return (file, issues)
    }
}
