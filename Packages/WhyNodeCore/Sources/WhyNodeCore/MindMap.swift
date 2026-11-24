import Foundation

/// 문서 하나의 편집 모델. 파일 구조(`WhyNodeFile`)를 감싸고 노드 생성 · 상태 전환 · 편집 규칙(SPEC 2~3절)을 적용한다.
public struct MindMap: Equatable, Sendable {
    public private(set) var file: WhyNodeFile
    private var indexById: [WID: Int] = [:]
    private var childIds: [WID: [WID]] = [:]

    public init(file: WhyNodeFile) {
        self.file = file
        reindex()
    }

    /// 질문이 비어 있는 루트 노드 하나만 있는 새 프로젝트
    public static func new(now: Date = Date()) -> MindMap {
        let now = Timestamp.truncated(now)
        let root = Node(parentId: nil, question: "", status: .empty, createdAt: now, updatedAt: now)
        let file = WhyNodeFile(project: ProjectMeta(createdAt: now, updatedAt: now), rootId: root.id, nodes: [root])
        return MindMap(file: file)
    }

    public static func == (lhs: MindMap, rhs: MindMap) -> Bool {
        lhs.file == rhs.file
    }

    // 조회

    public var rootId: WID { file.rootId }
    public var nodes: [Node] { file.nodes }
    public var root: Node { self[rootId]! }

    public subscript(id: WID) -> Node? {
        indexById[id].map { file.nodes[$0] }
    }

    public func children(of id: WID) -> [Node] {
        (childIds[id] ?? []).compactMap { self[$0] }
    }

    public func childIDs(of id: WID) -> [WID] {
        childIds[id] ?? []
    }

    /// 루트부터 `id`의 부모까지 (자기 자신 제외)
    public func ancestors(of id: WID) -> [Node] {
        var chain: [Node] = []
        var current = self[id]?.parentId
        while let pid = current, let parent = self[pid] {
            chain.append(parent)
            current = parent.parentId
        }
        return chain.reversed()
    }

    public func siblings(of id: WID) -> [Node] {
        guard let pid = self[id]?.parentId else { return [] }
        return children(of: pid).filter { $0.id != id }
    }

    /// `id`와 그 아래 가지 전체의 id
    public func subtreeIDs(of id: WID) -> [WID] {
        guard self[id] != nil else { return [] }
        var result: [WID] = []
        var stack = [id]
        while let next = stack.popLast() {
            result.append(next)
            stack.append(contentsOf: childIds[next] ?? [])
        }
        return result
    }

    public func isDescendant(_ id: WID, of ancestor: WID) -> Bool {
        ancestors(of: id).contains { $0.id == ancestor }
    }

    // 노드 생성 (SPEC 2.3)

    /// 빈 루트에 주제를 입력하면 답변 대기 상태가 된다.
    public mutating func setRootQuestion(_ question: String, now: Date = Date()) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(rootId, now: now) {
            $0.question = trimmed
            $0.status = .pending
            $0.error = nil
        }
    }

    /// 추가 질문을 골라 자식 노드를 만든다. 만든 노드 id를 돌려준다.
    @discardableResult
    public mutating func addChild(of parentId: WID, suggestion suggestionId: WID, now: Date = Date()) -> WID? {
        guard let parent = self[parentId],
              let suggestion = parent.suggestions.first(where: { $0.id == suggestionId }),
              suggestion.usedBy == nil
        else { return nil }
        let childId = insertChild(of: parentId, question: suggestion.text, now: now)
        update(parentId, now: now, touch: false) { node in
            if let i = node.suggestions.firstIndex(where: { $0.id == suggestionId }) {
                node.suggestions[i].usedBy = childId
            }
        }
        return childId
    }

    /// 직접 입력한 질문으로 자식 노드를 만든다.
    @discardableResult
    public mutating func addCustomChild(of parentId: WID, question: String, now: Date = Date()) -> WID? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self[parentId] != nil, !trimmed.isEmpty else { return nil }
        return insertChild(of: parentId, question: trimmed, now: now)
    }

    private mutating func insertChild(of parentId: WID, question: String, now: Date) -> WID {
        let now = Timestamp.truncated(now)
        let position = Layout.childPosition(in: self, parentId: parentId)
        let node = Node(parentId: parentId, question: question, status: .pending, position: position, createdAt: now, updatedAt: now)
        file.nodes.append(node)
        indexById[node.id] = file.nodes.count - 1
        childIds[parentId, default: []].append(node.id)
        touchProject(now)
        return node.id
    }

    // 상태 전환 (SPEC 3.1)

    /// 답변 다시 받기: 기존 답변 · 요약 · 추가 질문 · 참조 · 생성 정보를 보존한 채 대기 상태가 된다.
    public mutating func beginRegenerate(_ id: WID, now: Date = Date()) {
        guard let node = self[id], node.status != .empty, node.status != .pending else { return }
        update(id, now: now) {
            $0.status = .pending
            $0.error = nil
        }
    }

    /// 질문 수정: 질문과 답변이 어긋나지 않도록 답변 관련 값과 미사용 추가 질문을 비운다.
    public mutating func editQuestion(_ id: WID, to question: String, now: Date = Date()) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        // 그대로 확인만 누르면 아무것도 바꾸지 않는다(답변을 지우고 다시 요청하지 않는다).
        guard let node = self[id], !trimmed.isEmpty, trimmed != node.question else { return }
        update(id, now: now) {
            $0.question = trimmed
            $0.answer = nil
            $0.summary = nil
            $0.refs = []
            $0.generation = nil
            $0.suggestions.removeAll { $0.usedBy == nil }
            $0.status = .pending
            $0.error = nil
        }
    }

    /// 검증을 마친 답변을 반영한다. 대기 중이 아닌 노드(취소 · 삭제됨)에는 반영하지 않는다.
    public mutating func applyAnswer(_ id: WID, _ answer: ValidatedAnswer, generation: Generation, now: Date = Date()) {
        guard self[id]?.status == .pending else { return }
        update(id, now: now) { node in
            node.answer = answer.answer
            node.summary = answer.summary
            node.suggestions = node.suggestions.filter { $0.usedBy != nil } + answer.suggestions.map { Suggestion(text: $0) }
            node.refs = answer.refs
            node.generation = generation
            node.status = .done
            node.error = nil
        }
    }

    /// 요청 실패: 기존 값은 보존하고 오류 상태로 둔다.
    public mutating func failRequest(_ id: WID, message: String, now: Date = Date()) {
        guard self[id]?.status == .pending else { return }
        update(id, now: now) {
            $0.status = .error
            $0.error = message
        }
    }

    /// 실행 취소로 되살린 상태에 `other`(되돌리기 직전 상태)의 AI 결과를 옮긴다.
    /// AI 답변은 실행 취소 단계가 아니므로, 되살린 시점에 답을 기다리던 노드라도 그 사이 받은 답은 남긴다.
    /// 질문이 같고 `other`에서 답이 끝난(done · error) 노드만 옮겨, 질문 수정 · 다시 받기를 되돌리는 경우는 건드리지 않는다.
    public mutating func adoptAnswers(from other: MindMap) {
        for i in file.nodes.indices where file.nodes[i].status == .pending {
            guard let source = other[file.nodes[i].id], source.question == file.nodes[i].question,
                  source.status == .done || source.status == .error
            else { continue }
            file.nodes[i].answer = source.answer
            file.nodes[i].summary = source.summary
            file.nodes[i].suggestions = source.suggestions
            file.nodes[i].refs = source.refs
            file.nodes[i].generation = source.generation
            file.nodes[i].status = source.status
            file.nodes[i].error = source.error
            file.nodes[i].updatedAt = source.updatedAt
        }
    }

    /// 진행 중인 요청이 없는 대기 노드를 중단 상태로 바꾼다. 실행 취소로 되돌린 대기 노드가 영영 기다리지 않게 한다.
    /// 열 때의 복구(`Integrity.repair`)와 같이 수정 시각은 건드리지 않는다.
    public mutating func interruptPending(except inFlight: Set<WID>) {
        for i in file.nodes.indices where file.nodes[i].status == .pending && !inFlight.contains(file.nodes[i].id) {
            file.nodes[i].status = .error
            file.nodes[i].error = Integrity.interruptedMessage
        }
    }

    /// 노드에 쌓아 두는 미사용 추가 질문의 최대 개수 (SPEC 2.3)
    public static let maxOpenSuggestions = 12

    /// 추가 질문 다시 받기 결과: 새 질문을 미사용 목록 맨 앞에 쌓는다. 미사용이 최대 개수를 넘으면 가장 오래된 것부터 뺀다.
    /// 사용된 항목은 그대로 둔다. 답변이 있는(done) 노드에만 반영해, 질문 수정 · 다시 받기 중에 늦게 온 결과가 붙지 않게 한다.
    public mutating func addSuggestions(_ id: WID, _ texts: [String], now: Date = Date()) {
        guard self[id]?.status == .done, !texts.isEmpty else { return }
        update(id, now: now) { node in
            let used = node.suggestions.filter { $0.usedBy != nil }
            let open = texts.map { Suggestion(text: $0) } + node.suggestions.filter { $0.usedBy == nil }
            node.suggestions = used + open.prefix(Self.maxOpenSuggestions)
        }
    }

    // 편집 (SPEC 3.2)

    /// 노드와 그 아래 가지 전체를 삭제한다. 루트는 삭제할 수 없다.
    public mutating func deleteSubtree(_ id: WID, now: Date = Date()) {
        guard id != rootId, let node = self[id] else { return }
        let removed = Set(subtreeIDs(of: id))
        file.nodes.removeAll { removed.contains($0.id) }
        for i in file.nodes.indices {
            file.nodes[i].refs.removeAll { removed.contains($0.nodeId) }
            for j in file.nodes[i].suggestions.indices {
                if let used = file.nodes[i].suggestions[j].usedBy, removed.contains(used) {
                    file.nodes[i].suggestions[j].usedBy = nil
                }
            }
        }
        reindex()
        if let pid = node.parentId {
            update(pid, now: now) { _ in }
        } else {
            touchProject(Timestamp.truncated(now))
        }
    }

    /// 가지 접기 · 펼치기. 자식이 있는 루트 외 노드만 접을 수 있다.
    public mutating func setCollapsed(_ id: WID, _ collapsed: Bool, now: Date = Date()) {
        guard id != rootId, !(childIds[id] ?? []).isEmpty || !collapsed else { return }
        update(id, now: now) { $0.collapsed = collapsed }
    }

    /// 노드 하나의 글자 크기를 바꾼다. 노드 크기는 그대로다.
    public mutating func setTextScale(_ id: WID, _ scale: Double, now: Date = Date()) {
        let scale = Node.clampedTextScale(scale)
        guard let node = self[id], node.textScale != scale else { return }
        update(id, now: now) { $0.textScale = scale }
    }

    /// 사용자가 직접 옮긴 노드는 자동 배치에서 제외한다.
    public mutating func move(_ id: WID, to point: (x: Double, y: Double), pinned: Bool = true, now: Date = Date()) {
        update(id, now: now) {
            $0.position = Position(x: point.x, y: point.y, pinned: pinned || $0.position.pinned)
        }
    }

    /// 자동 배치 결과 반영. 사용자가 고정한 노드는 건드리지 않는다.
    public mutating func applyLayout(_ positions: [WID: (x: Double, y: Double)]) {
        for (id, point) in positions {
            guard let i = indexById[id], !file.nodes[i].position.pinned else { continue }
            file.nodes[i].position.x = point.x
            file.nodes[i].position.y = point.y
        }
    }

    /// 시뮬레이션 결과 반영 (SPEC 2.6). 루트만 제자리에 두고 나머지는 고정 여부와 상관없이 옮긴다.
    public mutating func arrange(_ positions: [WID: (x: Double, y: Double)]) {
        for (id, point) in positions where id != rootId {
            guard let i = indexById[id] else { continue }
            file.nodes[i].position.x = point.x
            file.nodes[i].position.y = point.y
        }
    }

    // 사용량

    /// AI 사용량을 누적한다. 내용 수정이 아니므로 수정 시각은 바꾸지 않는다.
    public mutating func addUsage(_ usage: TokenUsage) {
        file.project.usage += usage
    }

    /// 실행 취소로 이전 상태를 되살릴 때 사용량은 지금 값을 유지한다.
    public mutating func keepUsage(_ usage: TokenUsage) {
        file.project.usage = usage
    }

    // 내부

    private mutating func update(_ id: WID, now: Date, touch: Bool = true, _ change: (inout Node) -> Void) {
        guard let i = indexById[id] else { return }
        change(&file.nodes[i])
        let now = Timestamp.truncated(now)
        if touch {
            file.nodes[i].updatedAt = max(now, file.nodes[i].createdAt)
        }
        touchProject(now)
    }

    private mutating func touchProject(_ now: Date) {
        file.project.updatedAt = max(now, file.project.createdAt)
    }

    private mutating func reindex() {
        file.nodes.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        indexById = [:]
        childIds = [:]
        for (i, node) in file.nodes.enumerated() {
            indexById[node.id] = i
            if let pid = node.parentId {
                childIds[pid, default: []].append(node.id)
            }
        }
    }
}
