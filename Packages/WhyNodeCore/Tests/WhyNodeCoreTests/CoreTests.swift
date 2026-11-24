import Foundation
import Testing
@testable import WhyNodeCore

private let t0 = Timestamp.date(from: "2026-11-23T01:00:00.000Z")!

private func answered(_ map: inout MindMap, _ id: WID, suggestions: [String] = ["원리는 무엇일까?", "왜 중요할까?", "한계는 어디까지일까?"]) {
    let validated = ValidatedAnswer(answer: "답변입니다. 두 번째 문장.", summary: "요약", suggestions: suggestions, refs: [], removed: [])
    map.applyAnswer(id, validated, generation: MockProvider().generation(at: t0), now: t0.addingTimeInterval(1))
}

/// `#require`는 mutating 호출을 감쌀 수 없어 결과만 받아 확인한다.
private func unwrap<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, sourceLocation: sourceLocation)
}

@Suite("직렬화")
struct CodecTests {
    @Test func 왕복_저장하면_같은_문서가_나온다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("레이트레이싱", now: t0)
        answered(&map, map.rootId)
        let child = try unwrap(map.addChild(of: map.rootId, suggestion: map.root.suggestions[0].id, now: t0.addingTimeInterval(2)))
        answered(&map, child)

        let data = try WhyNodeCodec.encode(map.file)
        let decoded = try WhyNodeCodec.decode(data)
        #expect(decoded == map.file)
    }

    @Test func 소문자_UUID와_밀리초_시각_null_필드를_쓴다() throws {
        let map = MindMap.new(now: t0)
        let json = String(decoding: try WhyNodeCodec.encode(map.file), as: UTF8.self)
        #expect(json.contains(map.rootId.description))
        #expect(!json.contains(map.rootId.uuid.uuidString))
        #expect(json.contains("\"2026-11-23T01:00:00.000Z\""))
        #expect(json.contains("\"answer\" : null"))
        #expect(json.contains("\"generation\" : null"))
    }

    @Test func 상위_스키마_버전은_열지_않는다() throws {
        var object = try JSONSerialization.jsonObject(with: WhyNodeCodec.encode(MindMap.new(now: t0).file)) as! [String: Any]
        object["schemaVersion"] = 6
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CodecError.unsupportedSchemaVersion(6)) { try WhyNodeCodec.decode(data) }
        object["schemaVersion"] = 0
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CodecError.invalidSchemaVersion(0)) { try WhyNodeCodec.decode(old) }
    }

    @Test func v3_문서는_사용량을_0으로_채워_연다() throws {
        var object = try JSONSerialization.jsonObject(with: WhyNodeCodec.encode(MindMap.new(now: t0).file)) as! [String: Any]
        object["schemaVersion"] = 3
        var project = object["project"] as! [String: Any]
        project["usage"] = nil
        object["project"] = project
        let decoded = try WhyNodeCodec.decode(JSONSerialization.data(withJSONObject: object))
        #expect(decoded.project.usage == .zero)
        #expect(decoded.schemaVersion == WhyNodeFile.currentSchemaVersion)
    }

    @Test func v4_문서는_노드_크기와_색을_기본값으로_채워_연다() throws {
        var object = try JSONSerialization.jsonObject(with: WhyNodeCodec.encode(MindMap.new(now: t0).file)) as! [String: Any]
        object["schemaVersion"] = 4
        object["nodes"] = (object["nodes"] as! [[String: Any]]).map { node in
            var node = node
            node["sizeScale"] = nil
            node["fillColor"] = nil
            node["textColor"] = nil
            return node
        }
        let decoded = try WhyNodeCodec.decode(JSONSerialization.data(withJSONObject: object))
        #expect(decoded.nodes.allSatisfy { $0.sizeScale == 1 && $0.fillColor == nil && $0.textColor == nil })
    }

    @Test func 시작_화면_요약은_루트_주제와_노드_수를_읽는다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("레이트레이싱", now: t0)
        _ = map.addCustomChild(of: map.rootId, question: "BVH는?", now: t0)
        let preview = try #require(WhyNodeCodec.preview(WhyNodeCodec.encode(map.file)))
        #expect(preview.topic == "레이트레이싱")
        #expect(preview.nodeCount == 2)
        #expect(preview.updatedAt == map.file.project.updatedAt)
        #expect(WhyNodeCodec.preview(Data("{}".utf8)) == nil)
    }

    @Test func v2_문서는_글자_크기를_기본값으로_채워_연다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("주제", now: t0)
        var object = try JSONSerialization.jsonObject(with: WhyNodeCodec.encode(map.file)) as! [String: Any]
        object["schemaVersion"] = 2
        object["nodes"] = (object["nodes"] as! [[String: Any]]).map { node in
            var node = node
            node["textScale"] = nil
            return node
        }
        let decoded = try WhyNodeCodec.decode(JSONSerialization.data(withJSONObject: object))
        #expect(decoded.schemaVersion == WhyNodeFile.currentSchemaVersion)
        #expect(decoded.nodes.allSatisfy { $0.textScale == 1 })
        #expect(decoded.nodes.map(\.question) == map.file.nodes.map(\.question))
    }

    @Test func 정의되지_않은_필드와_빠진_필드를_거부한다() throws {
        var object = try JSONSerialization.jsonObject(with: WhyNodeCodec.encode(MindMap.new(now: t0).file)) as! [String: Any]
        var nodes = object["nodes"] as! [[String: Any]]
        nodes[0]["extra"] = 1
        object["nodes"] = nodes
        #expect(throws: CodecError.unexpectedKeys(path: "nodes[0]", keys: ["extra"])) {
            try WhyNodeCodec.decode(JSONSerialization.data(withJSONObject: object))
        }
        nodes[0]["extra"] = nil
        nodes[0]["summary"] = nil
        object["nodes"] = nodes
        #expect(throws: CodecError.missingKeys(path: "nodes[0]", keys: ["summary"])) {
            try WhyNodeCodec.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func v1_마이크로초_시간대_표기를_읽는다() {
        let date = Timestamp.date(from: "2026-10-06T16:18:16.030482+00:00")
        #expect(date.map(Timestamp.string) == "2026-10-06T16:18:16.030Z")
    }
}

@Suite("노드 편집")
struct MindMapTests {
    @Test func 새_프로젝트는_빈_루트_하나() {
        let map = MindMap.new(now: t0)
        #expect(map.nodes.count == 1)
        #expect(map.root.status == .empty)
        #expect(map.root.parentId == nil)
    }

    @Test func 추가_질문을_고르면_자식이_생기고_나머지는_남는다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("양자역학", now: t0)
        answered(&map, map.rootId)
        let picked = map.root.suggestions[1]
        let child = try unwrap(map.addChild(of: map.rootId, suggestion: picked.id, now: t0.addingTimeInterval(2)))

        #expect(map[child]?.status == .pending)
        #expect(map[child]?.question == picked.text)
        #expect(map.root.suggestions.first { $0.id == picked.id }?.usedBy == child)
        #expect(map.root.suggestions.filter { $0.usedBy == nil }.count == 2)
        #expect(map.addChild(of: map.rootId, suggestion: picked.id) == nil)
    }

    @Test func 답변_다시_받기가_실패해도_기존_답변을_보존한다() {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("양자역학", now: t0)
        answered(&map, map.rootId)
        map.beginRegenerate(map.rootId, now: t0.addingTimeInterval(3))
        #expect(map.root.status == .pending)
        #expect(map.root.answer != nil)
        map.failRequest(map.rootId, message: "네트워크 오류", now: t0.addingTimeInterval(4))
        #expect(map.root.status == .error)
        #expect(map.root.answer == "답변입니다. 두 번째 문장.")
        #expect(map.root.suggestions.count == 3)
    }

    @Test func 질문_수정은_답변과_미사용_질문을_비우고_사용된_질문은_남긴다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("양자역학", now: t0)
        answered(&map, map.rootId)
        let child = try unwrap(map.addChild(of: map.rootId, suggestion: map.root.suggestions[0].id, now: t0.addingTimeInterval(2)))
        map.editQuestion(map.rootId, to: "양자 컴퓨팅", now: t0.addingTimeInterval(3))

        #expect(map.root.answer == nil)
        #expect(map.root.summary == nil)
        #expect(map.root.status == .pending)
        #expect(map.root.suggestions.map(\.usedBy) == [child])
        #expect(map[child] != nil)
    }

    @Test func 삭제하면_가지가_사라지고_부모_질문을_다시_고를_수_있다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("양자역학", now: t0)
        answered(&map, map.rootId)
        let a = try unwrap(map.addChild(of: map.rootId, suggestion: map.root.suggestions[0].id, now: t0.addingTimeInterval(2)))
        answered(&map, a)
        let b = try unwrap(map.addCustomChild(of: a, question: "직접 질문", now: t0.addingTimeInterval(3)))
        let c = try unwrap(map.addCustomChild(of: map.rootId, question: "다른 가지", now: t0.addingTimeInterval(4)))
        answered(&map, c)
        _ = b

        map.deleteSubtree(a, now: t0.addingTimeInterval(5))
        #expect(map.nodes.count == 2)
        #expect(map.root.suggestions.allSatisfy { $0.usedBy == nil })
        map.deleteSubtree(map.rootId)
        #expect(map.nodes.count == 2)
    }

    @Test func 루트와_자식_없는_노드는_접을_수_없다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("주제", now: t0)
        let a = try unwrap(map.addCustomChild(of: map.rootId, question: "A", now: t0))
        map.setCollapsed(map.rootId, true)
        map.setCollapsed(a, true)
        #expect(!map.root.collapsed)
        #expect(map[a]?.collapsed == false)
        _ = map.addCustomChild(of: a, question: "B", now: t0)
        map.setCollapsed(a, true)
        #expect(map[a]?.collapsed == true)
    }

    @Test func 대기_중이_아닌_노드에는_늦게_온_답변을_반영하지_않는다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("주제", now: t0)
        let a = try unwrap(map.addCustomChild(of: map.rootId, question: "A", now: t0))
        map.deleteSubtree(a)
        answered(&map, a)
        #expect(map[a] == nil)
    }

    @Test func 노드_글자_크기는_범위_안으로_맞추고_왕복_저장된다() throws {
        var map = MindMap.new(now: t0)
        map.setTextScale(map.rootId, 1.234, now: t0)
        #expect(map.root.textScale == 1.23)
        map.setTextScale(map.rootId, 10, now: t0)
        #expect(map.root.textScale == Node.textScaleRange.upperBound)
        map.setTextScale(map.rootId, .nan, now: t0)
        #expect(map.root.textScale == 1)
        map.setTextScale(map.rootId, 1.5, now: t0)
        #expect(try WhyNodeCodec.decode(WhyNodeCodec.encode(map.file)) == map.file)
    }

    @Test func 질문을_그대로_두고_확인하면_아무것도_바꾸지_않는다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("주제", now: t0)
        answered(&map, map.rootId)
        let before = map
        map.editQuestion(map.rootId, to: "  주제 ", now: t0.addingTimeInterval(5))
        #expect(map == before)
    }

    @Test func 늦게_온_추가_질문은_답변이_있는_노드에만_붙는다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("주제", now: t0)
        map.addSuggestions(map.rootId, ["늦게 온 질문"], now: t0)
        #expect(map.root.suggestions.isEmpty)
        answered(&map, map.rootId, suggestions: ["처음 질문"])
        map.addSuggestions(map.rootId, ["새 질문"], now: t0)
        #expect(map.root.suggestions.map(\.text) == ["새 질문", "처음 질문"])
    }

    @Test func 추가_질문은_최대_개수까지_쌓이고_사용된_질문은_남는다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("주제", now: t0)
        answered(&map, map.rootId, suggestions: ["Q0"])
        let child = try unwrap(map.addChild(of: map.rootId, suggestion: map.root.suggestions[0].id, now: t0))
        for round in 1...5 {
            map.addSuggestions(map.rootId, (1...3).map { "R\(round)-\($0)" }, now: t0)
        }
        let open = map.root.suggestions.filter { $0.usedBy == nil }
        #expect(open.count == MindMap.maxOpenSuggestions)
        #expect(open.first?.text == "R5-1")
        #expect(map.root.suggestions.contains { $0.usedBy == child })
    }

    @Test func 사용량은_누적되고_저장된다() throws {
        var map = MindMap.new(now: t0)
        let before = map.file.project.updatedAt
        map.addUsage(TokenUsage(inputTokens: 100, outputTokens: 20, costUSD: 0.01))
        map.addUsage(TokenUsage(inputTokens: 50, outputTokens: 5))
        #expect(map.file.project.usage == TokenUsage(inputTokens: 150, outputTokens: 25, costUSD: 0.01, requests: 2))
        #expect(map.file.project.updatedAt == before)
        #expect(try WhyNodeCodec.decode(WhyNodeCodec.encode(map.file)) == map.file)
    }

    @Test func 되살린_대기_노드는_그사이_받은_답을_이어받는다() throws {
        var before = MindMap.new(now: t0)
        before.setRootQuestion("주제", now: t0)
        let a = try unwrap(before.addCustomChild(of: before.rootId, question: "A", now: t0))
        var after = before
        answered(&after, before.rootId)
        answered(&after, a)
        after.editQuestion(a, to: "A2", now: t0.addingTimeInterval(2))
        var restored = before
        restored.adoptAnswers(from: after)
        // 질문이 같은 루트는 답을 이어받고, 질문이 바뀐 A는 그대로 대기다.
        #expect(restored.root.status == .done)
        #expect(restored.root.answer == after.root.answer)
        #expect(restored[a]?.status == .pending)
    }

    @Test func 노드_크기와_색을_바꾸고_원래대로_되돌린다() throws {
        var map = MindMap.new(now: t0)
        let id = map.rootId
        map.setSizeScale(id, 5, now: t0)
        #expect(map.root.sizeScale == Node.sizeScaleRange.upperBound)
        map.setColors(id, fill: "blue", text: "#112233", now: t0)
        #expect(map.root.fillColor == "blue" && map.root.textColor == "#112233")
        map.setColors(id, fill: "nope", now: t0)
        #expect(map.root.fillColor == "blue")
        map.setColors(id, fill: .some(nil), now: t0)
        #expect(map.root.fillColor == nil && map.root.textColor == "#112233")
        #expect(try WhyNodeCodec.decode(WhyNodeCodec.encode(map.file)) == map.file)
        map.resetStyle(id, now: t0)
        #expect(!map.root.hasCustomStyle)
    }

    @Test func 알_수_없는_색과_범위_밖_크기는_열_때_고친다() throws {
        var map = MindMap.new(now: t0)
        var file = map.file
        file.nodes[0].fillColor = "#GGGGGG"
        file.nodes[0].sizeScale = 9
        let (fixed, issues) = Integrity.repair(file)
        #expect(fixed.nodes[0].fillColor == nil)
        #expect(fixed.nodes[0].sizeScale == Node.sizeScaleRange.upperBound)
        #expect(issues.contains(.invalidColorCleared(map.rootId)))
        map = MindMap(file: fixed)
        #expect(map.root.sizeScale == 2)
    }

    @Test func 요청이_없는_대기_노드만_중단_상태가_된다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("주제", now: t0)
        let a = try unwrap(map.addCustomChild(of: map.rootId, question: "A", now: t0))
        let b = try unwrap(map.addCustomChild(of: map.rootId, question: "B", now: t0))
        let before = map[a]?.updatedAt
        map.interruptPending(except: [b])
        #expect(map.root.status == .error)
        #expect(map[a]?.status == .error)
        #expect(map[a]?.error == Integrity.interruptedMessage)
        #expect(map[a]?.updatedAt == before)
        #expect(map[b]?.status == .pending)
    }
}

@Suite("무결성 복구")
struct IntegrityTests {
    @Test func 고아_순환_끊긴_참조_중단된_요청을_복구한다() {
        let root = Node(parentId: nil, question: "루트", status: .done, createdAt: t0, updatedAt: t0)
        let ghost = WID()
        let orphan = Node(parentId: ghost, question: "고아", status: .done, refs: [NodeRef(nodeId: ghost, reason: "x")], createdAt: t0, updatedAt: t0)
        var a = Node(parentId: nil, question: "A", status: .pending, createdAt: t0, updatedAt: t0)
        let b = Node(parentId: a.id, question: "B", status: .done, suggestions: [Suggestion(text: "s", usedBy: ghost)], createdAt: t0, updatedAt: t0)
        a.parentId = b.id
        let file = WhyNodeFile(project: ProjectMeta(createdAt: t0, updatedAt: t0), rootId: root.id, nodes: [root, orphan, a, b])

        let (repaired, issues) = Integrity.repair(file)
        let map = MindMap(file: repaired)
        #expect(map[orphan.id]?.parentId == root.id)
        #expect(map[orphan.id]?.refs.isEmpty == true)
        #expect(map[b.id]?.suggestions.first?.usedBy == nil)
        #expect(map[a.id]?.status == .error)
        #expect(map[a.id]?.error == Integrity.interruptedMessage)
        #expect(map.nodes.allSatisfy { $0.id == root.id || !map.ancestors(of: $0.id).isEmpty })
        #expect(issues.contains(.orphanReattached(orphan.id)))
        #expect(issues.contains { if case .cycleBroken = $0 { true } else { false } })
    }
}

@Suite("맥락 패키지")
struct ContextTests {
    @Test func 루트_요청은_경로_형제_색인이_비어_있다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("레이트레이싱", now: t0)
        let context = try #require(ContextBuilder.answer(for: map.rootId, in: map))
        #expect(context.path.isEmpty)
        #expect(context.siblings == [])
        #expect(context.index.isEmpty)
        #expect(context.parentAnswer == nil)
        #expect(context.topic == "레이트레이싱")
    }

    @Test func 자식_요청은_부모_답변과_형제를_담고_자기_자신은_색인에서_뺀다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("주제", now: t0)
        answered(&map, map.rootId)
        let a = try unwrap(map.addChild(of: map.rootId, suggestion: map.root.suggestions[0].id, now: t0.addingTimeInterval(2)))
        let b = try unwrap(map.addChild(of: map.rootId, suggestion: map.root.suggestions[1].id, now: t0.addingTimeInterval(3)))

        let context = try #require(ContextBuilder.answer(for: b, in: map))
        #expect(context.parentAnswer == map.root.answer)
        #expect(context.path.map(\.id) == [map.rootId.description])
        #expect(context.siblings?.map(\.id) == [a.description])
        #expect(!context.index.contains { $0.id == b.description })
        #expect(context.index.first?.id == map.rootId.description)
    }

    @Test func 추가_질문_요청은_현재_답변과_자식과_제외_목록을_담는다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("주제", now: t0)
        answered(&map, map.rootId)
        let a = try unwrap(map.addChild(of: map.rootId, suggestion: map.root.suggestions[0].id, now: t0.addingTimeInterval(2)))

        let context = try #require(ContextBuilder.suggest(for: map.rootId, in: map))
        #expect(context.kind == .suggest)
        #expect(context.answer == map.root.answer)
        #expect(context.children?.map(\.id) == [a.description])
        #expect(context.path.isEmpty)
        #expect(Set(context.exclude ?? []) == Set(map.root.suggestions.map(\.text)))
    }

    @Test func 요약이_없으면_답변_첫_문장을_쓴다() {
        let node = Node(parentId: nil, question: "q", answer: "첫 문장입니다. 둘째 문장입니다.", status: .done, createdAt: t0, updatedAt: t0)
        #expect(ContextBuilder.summary(of: node) == "첫 문장입니다")
    }

    @Test func 예산을_넘으면_요약을_빼고_그래도_넘으면_생략한다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("주제", now: t0)
        answered(&map, map.rootId)
        for i in 0..<20 {
            _ = map.addCustomChild(of: map.rootId, question: "질문 \(i) 입니다", now: t0.addingTimeInterval(Double(i)))
        }
        let target = map.childIDs(of: map.rootId)[0]
        let index = ContextBuilder.index(for: target, in: map, budget: 40)
        #expect(index.first?.id == map.rootId.description)
        #expect(index.count < 20)
    }
}

@Suite("응답 검증")
struct ValidationTests {
    @Test func 표면_중복과_기존_질문을_거른다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("양자역학", now: t0)
        answered(&map, map.rootId, suggestions: [])
        let a = try unwrap(map.addCustomChild(of: map.rootId, question: "관측이란 무엇일까?", now: t0))
        let response = AnswerResponse(
            answer: "답", summary: "요약",
            suggestions: ["관측이란 무엇일까요?", "도대체 관측이란 무엇일까", "중첩은 왜 깨질까?", "중첩은 왜 깨질까요?", "얽힘은 어떻게 생길까?"]
        )
        let validated = try ResponseValidator.validate(response, for: a, in: map)
        #expect(validated.suggestions == ["중첩은 왜 깨질까?", "얽힘은 어떻게 생길까?"])
        #expect(validated.removed.count == 3)
        #expect(!validated.needsMoreSuggestions)
    }

    @Test func 잘못된_참조를_제거한다() throws {
        var map = MindMap.new(now: t0)
        map.setRootQuestion("주제", now: t0)
        let a = try unwrap(map.addCustomChild(of: map.rootId, question: "A", now: t0))
        let b = try unwrap(map.addCustomChild(of: a, question: "B", now: t0))
        let c = try unwrap(map.addCustomChild(of: b, question: "C", now: t0))
        let other = try unwrap(map.addCustomChild(of: map.rootId, question: "D", now: t0))
        let raw: [AnswerResponse.RawRef] = [
            .init(nodeId: b.description, reason: "자기"),
            .init(nodeId: a.description, reason: "부모"),
            .init(nodeId: c.description, reason: "자식"),
            .init(nodeId: "없는-id", reason: "없음"),
            .init(nodeId: map.rootId.description, reason: "조부모"),
            .init(nodeId: other.description, reason: "다른 가지"),
            .init(nodeId: other.description.uppercased(), reason: "중복"),
        ]
        let refs = ResponseValidator.refs(raw, for: b, in: map)
        #expect(refs.map(\.nodeId) == [map.rootId, other])
    }

    @Test func 빈_답변은_오류() {
        let map = MindMap.new(now: t0)
        #expect(throws: ValidationError.emptyField("answer")) {
            try ResponseValidator.validate(AnswerResponse(answer: " ", summary: "s", suggestions: []), for: map.rootId, in: map)
        }
    }
}
