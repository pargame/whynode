import Foundation

/// 노드 · 프로젝트 · 추가 질문의 식별자. 파일에는 소문자 UUID 문자열로 저장한다 (SPEC 7.1).
public struct WID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let uuid: UUID

    public init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    public init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.uuid = uuid
    }

    public var description: String { uuid.uuidString.lowercased() }

    public static func < (lhs: WID, rhs: WID) -> Bool {
        lhs.description < rhs.description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = WID(string: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "id is not a UUID: \(raw)")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public enum NodeStatus: String, Codable, Sendable {
    case empty, pending, done, error
}

public struct Suggestion: Codable, Equatable, Sendable, Identifiable {
    public var id: WID
    public var text: String
    /// 이 질문으로 생성된 자식 노드. 제안 목록의 사용 표시 전용이며 트리 연결의 기준은 자식의 `parentId`다.
    public var usedBy: WID?

    public init(id: WID = WID(), text: String, usedBy: WID? = nil) {
        self.id = id
        self.text = text
        self.usedBy = usedBy
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(usedBy, forKey: .usedBy)
    }
}

public struct NodeRef: Codable, Equatable, Sendable {
    public var nodeId: WID
    public var reason: String

    public init(nodeId: WID, reason: String) {
        self.nodeId = nodeId
        self.reason = reason
    }
}

public struct Position: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    /// 사용자가 직접 옮겨 자동 배치에서 제외된 노드
    public var pinned: Bool

    public init(x: Double = 0, y: Double = 0, pinned: Bool = false) {
        self.x = x
        self.y = y
        self.pinned = pinned
    }
}

public enum Connection: String, Codable, Sendable {
    case apiKey = "api_key"
    case oauth
    case cli
}

public struct Generation: Codable, Equatable, Sendable {
    public var provider: String
    public var connection: Connection
    public var model: String
    public var promptVersion: String
    public var generatedAt: Date

    public init(provider: String, connection: Connection, model: String, promptVersion: String, generatedAt: Date) {
        self.provider = provider
        self.connection = connection
        self.model = model
        self.promptVersion = promptVersion
        self.generatedAt = generatedAt
    }
}

public struct Node: Codable, Equatable, Sendable, Identifiable {
    public var id: WID
    public var parentId: WID?
    public var question: String
    public var answer: String?
    public var summary: String?
    public var status: NodeStatus
    public var error: String?
    public var suggestions: [Suggestion]
    public var refs: [NodeRef]
    public var position: Position
    public var collapsed: Bool
    /// 이 노드의 글자 크기 배율 (SPEC 7.4). 노드 크기는 그대로이고 글자만 바뀐다. 앱 전체 글자 크기 설정과 곱해 쓴다.
    public var textScale: Double
    public var generation: Generation?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: WID = WID(),
        parentId: WID?,
        question: String,
        answer: String? = nil,
        summary: String? = nil,
        status: NodeStatus,
        error: String? = nil,
        suggestions: [Suggestion] = [],
        refs: [NodeRef] = [],
        position: Position = Position(),
        collapsed: Bool = false,
        textScale: Double = 1,
        generation: Generation? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.parentId = parentId
        self.question = question
        self.answer = answer
        self.summary = summary
        self.status = status
        self.error = error
        self.suggestions = suggestions
        self.refs = refs
        self.position = position
        self.collapsed = collapsed
        self.textScale = textScale
        self.generation = generation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // null 값도 키를 남겨 스키마의 필수 필드를 항상 채운다 (SPEC 7.3)
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(parentId, forKey: .parentId)
        try c.encode(question, forKey: .question)
        try c.encode(answer, forKey: .answer)
        try c.encode(summary, forKey: .summary)
        try c.encode(status, forKey: .status)
        try c.encode(error, forKey: .error)
        try c.encode(suggestions, forKey: .suggestions)
        try c.encode(refs, forKey: .refs)
        try c.encode(position, forKey: .position)
        try c.encode(collapsed, forKey: .collapsed)
        try c.encode(textScale, forKey: .textScale)
        try c.encode(generation, forKey: .generation)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

extension Node {
    public static let textScaleRange: ClosedRange<Double> = 0.6...2.5

    /// 범위를 벗어나거나 수가 아닌 값을 허용 범위로 맞추고, 소수 둘째 자리로 자른다.
    public static func clampedTextScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return (min(max(value, textScaleRange.lowerBound), textScaleRange.upperBound) * 100).rounded() / 100
    }
}

public struct ProjectMeta: Codable, Equatable, Sendable {
    public var id: WID
    public var createdAt: Date
    public var updatedAt: Date
    /// 이 프로젝트에서 쓴 AI 사용량 누적 (SPEC 7.4). 실행 취소로 되돌아가지 않는다.
    public var usage: TokenUsage

    public init(id: WID = WID(), createdAt: Date, updatedAt: Date, usage: TokenUsage = .zero) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.usage = usage
    }
}

/// `.whynode` 파일의 최상위 구조 (SPEC 7.3)
public struct WhyNodeFile: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 4

    public var schemaVersion: Int
    public var project: ProjectMeta
    public var rootId: WID
    public var nodes: [Node]

    public init(schemaVersion: Int = WhyNodeFile.currentSchemaVersion, project: ProjectMeta, rootId: WID, nodes: [Node]) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.rootId = rootId
        self.nodes = nodes
    }
}
