import Foundation

public enum CodecError: Error, Equatable, LocalizedError {
    case notJSONObject
    case unsupportedSchemaVersion(Int)
    case missingSchemaVersion
    case invalidSchemaVersion(Int)
    case unexpectedKeys(path: String, keys: [String])
    case missingKeys(path: String, keys: [String])

    public var errorDescription: String? {
        switch self {
        case .notJSONObject:
            L("This isn't a WhyNode document.")
        case .unsupportedSchemaVersion(let version):
            L("This document is from a newer version (schemaVersion \(version)). Please update the app.")
        case .missingSchemaVersion:
            L("This document has no schemaVersion.")
        case .invalidSchemaVersion(let version):
            L("Unknown schemaVersion (\(version)).")
        case .unexpectedKeys(let path, let keys):
            L("\(path) has undefined fields: \(keys.joined(separator: ", "))")
        case .missingKeys(let path, let keys):
            L("\(path) is missing required fields: \(keys.joined(separator: ", "))")
        }
    }
}

/// RFC 3339 UTC 밀리초 시각 표기 (SPEC 7.1)
public enum Timestamp {
    /// 포매터의 소수 초 절삭 오차를 피하려고 정수 밀리초에서 직접 만든다.
    public static func string(from date: Date) -> String {
        let ms = date.milliseconds
        let (seconds, fraction) = ms.quotientAndRemainder(dividingBy: 1000)
        let (whole, positiveFraction) = fraction < 0 ? (seconds - 1, fraction + 1000) : (seconds, fraction)
        let base = Date(timeIntervalSince1970: Double(whole)).formatted(Date.ISO8601FormatStyle())
        return base.dropLast() + String(format: ".%03dZ", positiveFraction)
    }

    /// 소수 초 자릿수와 시간대 표기가 달라도 읽는다. v1 파일의 마이크로초 · `+00:00` 표기도 허용한다.
    public static func date(from string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return Date(milliseconds: date.milliseconds)
        }
        if let date = try? Date.ISO8601FormatStyle().parse(string) {
            return Date(milliseconds: date.milliseconds)
        }
        let normalized = string.replacing(/\.(\d{3})\d+/) { ".\($0.output.1)" }
        if normalized != string {
            return date(from: normalized)
        }
        return nil
    }

    /// 파일 왕복 후에도 값이 같도록 밀리초 단위로 자른다.
    public static func truncated(_ date: Date) -> Date {
        Date(milliseconds: Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))
    }
}

extension Date {
    /// 정수 밀리초에서 만든 시각. 읽기 · 자르기 경로가 모두 이 값을 거쳐야 왕복 후에도 `==`가 성립한다.
    public init(milliseconds: Int64) {
        self.init(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    public var milliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
}

public enum WhyNodeCodec {
    public static func encode(_ file: WhyNodeFile) throws -> Data {
        var sorted = file
        sorted.nodes.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Timestamp.string(from: date))
        }
        return try encoder.encode(sorted)
    }

    /// 스키마 검사(버전 · 필드 집합) 후 디코딩한다. 무결성 복구는 `Integrity.repair`가 담당한다.
    public static func decode(_ data: Data) throws -> WhyNodeFile {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodecError.notJSONObject
        }
        guard let version = object["schemaVersion"] as? Int else {
            throw CodecError.missingSchemaVersion
        }
        guard version <= WhyNodeFile.currentSchemaVersion else {
            throw CodecError.unsupportedSchemaVersion(version)
        }
        // schemaVersion은 2부터 쓴다. v1 파일에는 이 필드가 없다.
        guard version >= 2 else {
            throw CodecError.invalidSchemaVersion(version)
        }
        let migrated = migrate(object, from: version)
        try SchemaGuard.check(migrated)
        let current = version == WhyNodeFile.currentSchemaVersion ? data : try JSONSerialization.data(withJSONObject: migrated)
        return try decoder().decode(WhyNodeFile.self, from: current)
    }

    /// 이전 스키마 버전에 없던 필드를 기본값으로 채운다 (SPEC 7.8). 이후 검사 · 디코딩은 현재 버전 기준이다.
    static func migrate(_ object: [String: Any], from version: Int) -> [String: Any] {
        guard version < WhyNodeFile.currentSchemaVersion else { return object }
        var result = object
        if version < 5, let nodes = result["nodes"] as? [Any] {
            result["nodes"] = nodes.map { value -> Any in
                guard var node = value as? [String: Any] else { return value }
                if node["sizeScale"] == nil { node["sizeScale"] = 1 }
                if node["fillColor"] == nil { node["fillColor"] = NSNull() }
                if node["textColor"] == nil { node["textColor"] = NSNull() }
                return node
            }
        }
        // v6에서 노드별 글자 크기(textScale)를 없앴다. 글자 크기는 앱이 질문 길이에 맞춰 정한다.
        if version < 6, let nodes = result["nodes"] as? [Any] {
            result["nodes"] = nodes.map { value -> Any in
                guard var node = value as? [String: Any] else { return value }
                node["textScale"] = nil
                return node
            }
        }
        if version < 4, var project = result["project"] as? [String: Any], project["usage"] == nil {
            project["usage"] = ["inputTokens": 0, "outputTokens": 0, "costUSD": 0, "requests": 0]
            result["project"] = project
        }
        result["schemaVersion"] = WhyNodeFile.currentSchemaVersion
        return result
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = Timestamp.date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp: \(raw)")
            }
            return date
        }
        return decoder
    }
}

/// 시작 화면에 보여 줄 프로젝트 요약. 전체를 디코딩하지 않고 필요한 값만 읽는다.
public struct ProjectPreview: Equatable, Sendable {
    /// 루트 노드의 질문(주제). 아직 입력하지 않았으면 빈 문자열.
    public var topic: String
    public var nodeCount: Int
    public var updatedAt: Date?

    public init(topic: String, nodeCount: Int, updatedAt: Date?) {
        self.topic = topic
        self.nodeCount = nodeCount
        self.updatedAt = updatedAt
    }
}

extension WhyNodeCodec {
    /// WhyNode 문서가 아니면 nil. 무결성 검사 · 복구는 하지 않는다.
    public static func preview(_ data: Data) -> ProjectPreview? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schemaVersion"] is Int,
              let nodes = object["nodes"] as? [[String: Any]]
        else { return nil }
        let rootId = object["rootId"] as? String
        let root = nodes.first { $0["id"] as? String == rootId }
        let updated = ((object["project"] as? [String: Any])?["updatedAt"] as? String).flatMap(Timestamp.date)
        return ProjectPreview(topic: root?["question"] as? String ?? "", nodeCount: nodes.count, updatedAt: updated)
    }
}

/// `additionalProperties: false`와 필수 필드 규칙을 검사한다 (SPEC 7.1).
enum SchemaGuard {
    static let file: Set<String> = ["schemaVersion", "project", "rootId", "nodes"]
    static let project: Set<String> = ["id", "createdAt", "updatedAt", "usage"]
    static let usage: Set<String> = ["inputTokens", "outputTokens", "costUSD", "requests"]
    static let node: Set<String> = [
        "id", "parentId", "question", "answer", "summary", "status", "error",
        "suggestions", "refs", "position", "collapsed", "sizeScale", "fillColor", "textColor", "generation", "createdAt", "updatedAt",
    ]
    static let suggestion: Set<String> = ["id", "text", "usedBy"]
    static let ref: Set<String> = ["nodeId", "reason"]
    static let position: Set<String> = ["x", "y", "pinned"]
    static let generation: Set<String> = ["provider", "connection", "model", "promptVersion", "generatedAt"]

    static func check(_ object: [String: Any]) throws {
        try keys(object, file, L("document"))
        if let project = object["project"] as? [String: Any] {
            try keys(project, Self.project, "project")
            if let usage = project["usage"] as? [String: Any] { try keys(usage, Self.usage, "project.usage") }
        }
        for (index, value) in (object["nodes"] as? [Any] ?? []).enumerated() {
            guard let node = value as? [String: Any] else { continue }
            let path = "nodes[\(index)]"
            try keys(node, Self.node, path)
            for (i, s) in (node["suggestions"] as? [Any] ?? []).enumerated() {
                if let s = s as? [String: Any] { try keys(s, suggestion, "\(path).suggestions[\(i)]") }
            }
            for (i, r) in (node["refs"] as? [Any] ?? []).enumerated() {
                if let r = r as? [String: Any] { try keys(r, ref, "\(path).refs[\(i)]") }
            }
            if let p = node["position"] as? [String: Any] { try keys(p, position, "\(path).position") }
            if let g = node["generation"] as? [String: Any] { try keys(g, generation, "\(path).generation") }
        }
    }

    private static func keys(_ object: [String: Any], _ expected: Set<String>, _ path: String) throws {
        let actual = Set(object.keys)
        let extra = actual.subtracting(expected)
        if !extra.isEmpty {
            throw CodecError.unexpectedKeys(path: path, keys: extra.sorted())
        }
        let missing = expected.subtracting(actual)
        if !missing.isEmpty {
            throw CodecError.missingKeys(path: path, keys: missing.sorted())
        }
    }
}
