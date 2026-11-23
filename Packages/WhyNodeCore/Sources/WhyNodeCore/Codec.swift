import Foundation

public enum CodecError: Error, Equatable, LocalizedError {
    case notJSONObject
    case unsupportedSchemaVersion(Int)
    case missingSchemaVersion
    case unexpectedKeys(path: String, keys: [String])
    case missingKeys(path: String, keys: [String])

    public var errorDescription: String? {
        switch self {
        case .notJSONObject:
            "WhyNode 문서 형식이 아닙니다."
        case .unsupportedSchemaVersion(let version):
            "더 새로운 버전(schemaVersion \(version))의 문서입니다. 앱을 업데이트해 주세요."
        case .missingSchemaVersion:
            "schemaVersion이 없는 문서입니다. v1 파일은 가져오기로 여세요."
        case .unexpectedKeys(let path, let keys):
            "\(path)에 정의되지 않은 필드가 있습니다: \(keys.joined(separator: ", "))"
        case .missingKeys(let path, let keys):
            "\(path)에 필수 필드가 없습니다: \(keys.joined(separator: ", "))"
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
        let migrated = migrate(object, from: version)
        try SchemaGuard.check(migrated)
        let current = version == WhyNodeFile.currentSchemaVersion ? data : try JSONSerialization.data(withJSONObject: migrated)
        return try decoder().decode(WhyNodeFile.self, from: current)
    }

    /// 이전 스키마 버전에 없던 필드를 기본값으로 채운다 (SPEC 7.8). 이후 검사 · 디코딩은 현재 버전 기준이다.
    static func migrate(_ object: [String: Any], from version: Int) -> [String: Any] {
        guard version < WhyNodeFile.currentSchemaVersion else { return object }
        var result = object
        if version < 3, let nodes = object["nodes"] as? [Any] {
            result["nodes"] = nodes.map { value -> Any in
                guard var node = value as? [String: Any] else { return value }
                if node["textScale"] == nil { node["textScale"] = 1 }
                return node
            }
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
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "시각 형식 오류: \(raw)")
            }
            return date
        }
        return decoder
    }
}

/// `additionalProperties: false`와 필수 필드 규칙을 검사한다 (SPEC 7.1).
enum SchemaGuard {
    static let file: Set<String> = ["schemaVersion", "project", "rootId", "nodes"]
    static let project: Set<String> = ["id", "createdAt", "updatedAt"]
    static let node: Set<String> = [
        "id", "parentId", "question", "answer", "summary", "status", "error",
        "suggestions", "refs", "position", "collapsed", "textScale", "generation", "createdAt", "updatedAt",
    ]
    static let suggestion: Set<String> = ["id", "text", "usedBy"]
    static let ref: Set<String> = ["nodeId", "reason"]
    static let position: Set<String> = ["x", "y", "pinned"]
    static let generation: Set<String> = ["provider", "connection", "model", "promptVersion", "generatedAt"]

    static func check(_ object: [String: Any]) throws {
        try keys(object, file, "문서")
        if let project = object["project"] as? [String: Any] {
            try keys(project, Self.project, "project")
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
