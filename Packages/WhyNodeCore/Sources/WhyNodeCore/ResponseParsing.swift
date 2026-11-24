import Foundation

extension Prompt {
    /// 맥락 패키지를 담은 사용자 메시지. 출력 필드 이름을 명시해 스키마를 강제하지 못하는 경로에서도 형식을 맞춘다.
    public static func userMessage(for context: ContextPackage) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(context)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let format = switch context.kind {
        case .answer:
            #"{"answer": "3–4 sentence answer", "summary": "one-line summary", "suggestions": ["3–4 follow-up questions"], "refs": [{"nodeId": "existing node id", "reason": "why it is related"}]}"#
        case .suggest:
            #"{"suggestions": ["3–4 follow-up questions"]}"#
        case .links:
            #"{"links": [{"a": "node id", "b": "node id", "reason": "why they are related"}]}"#
        }
        return """
        Context package:
        \(json)

        Output only one JSON object in the format below, with no other explanation.
        \(format)
        """
    }

    public static func schema(for kind: ContextPackage.Kind) -> String {
        switch kind {
        case .answer: answerSchema
        case .suggest: suggestSchema
        case .links: linksSchema
        }
    }

    static func schemaObject(for kind: ContextPackage.Kind) -> [String: Any] {
        let data = Data(schema(for: kind).utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// AI가 낸 텍스트에서 JSON 객체를 찾아 디코딩한다. 코드 블록 · 앞뒤 설명 · 여러 객체가 섞여 있어도
/// 원하는 타입으로 읽히는 첫 객체를 고른다.
public enum JSONExtract {
    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode(T.self, from: Data(text.utf8)) {
            return direct
        }
        for candidate in objects(in: text) {
            if let value = try? decoder.decode(T.self, from: Data(candidate.utf8)) {
                return value
            }
        }
        throw ProviderError.unreadableResponse(String(text.prefix(200)))
    }

    /// 문자열 안의 중괄호는 무시하며 최상위 JSON 객체 후보를 순서대로 뽑는다.
    static func objects(in text: String) -> [String] {
        var results: [String] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        for index in text.indices {
            let ch = text[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let s = start {
                    results.append(String(text[s...index]))
                    start = nil
                }
            default:
                break
            }
        }
        return results
    }
}

extension AnswerResponse {
    /// 필수 내용이 비었는지. 비었으면 다른 후보를 찾거나 실패로 본다.
    var isUsable: Bool {
        !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !suggestions.isEmpty
    }
}
