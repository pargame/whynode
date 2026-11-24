import SwiftUI
import WhyNodeCore

/// 한 문서 창의 AI 요청: 답변 · 추가 질문을 프로바이더에 보내고 결과를 검증해 문서에 반영한다 (SPEC 5.3, 6.4).
/// 요청은 앱 전체의 `AIRequestCenter`에 등록해 한도를 함께 쓰고, 쓸모가 없어지면 끊는다(SPEC 6.6).
@Observable
final class AIController {
    /// 설정(SettingsStore)에서 만든 프로바이더. 설정 전이면 nil.
    var provider: (any AIProvider)? {
        didSet { center?.limit = provider?.capabilities.maxConcurrentRequests ?? 1 }
    }
    /// 추가 질문 다시 받기 중인 노드. 노드 상태(`status`)와 별개인 화면 전용 로딩 상태다.
    private(set) var suggesting: Set<WID> = []
    var notice: String?
    /// 앱 전체 요청 관리. 화면이 나타날 때 연결한다.
    @ObservationIgnored var center: AIRequestCenter?

    static var notConfigured: String { String(localized: "AI isn't connected. Connect it in Settings on the toolbar.") }

    func requestAnswer(for id: WID, in document: WhyNodeDocument, undoManager: UndoManager?) {
        guard let center, let node = document.map[id], node.status == .pending,
              let context = ContextBuilder.answer(for: id, in: document.map)
        else { return }
        guard let provider else {
            document.perform("Answer Failed", undoManager: undoManager) { $0.failRequest(id, message: Self.notConfigured) }
            notice = Self.notConfigured
            return
        }
        let key = AIRequestCenter.Key(document: ObjectIdentifier(document), node: id, kind: .answer)
        let question = node.question
        if let existing = center.request(for: key) {
            // 같은 질문으로 이미 요청 중이면 그대로 두고, 질문이 바뀌었으면 옛 요청을 끊고 새로 보낸다.
            if existing.question == question { return }
            center.cancel(existing.id)
        }
        let requestID = UUID()
        document.inFlight.insert(id)
        let task = Task { [weak document] in
            defer {
                center.finish(requestID)
                if center.request(for: key) == nil { document?.inFlight.remove(id) }
            }
            do {
                try await center.acquire(requestID)
                defer { center.release() }
                let validated = try await measure(.answer, context: context, document: document) {
                    try await self.retryingOnce {
                        let response = try await provider.answer(context)
                        guard let document else { throw CancellationError() }
                        return try ResponseValidator.validate(response, for: id, in: document.map)
                    }
                }
                guard let document, Self.isCurrent(document.map[id], status: .pending, question: question) else { return }
                document.perform("Receive Answer", undoManager: undoManager) {
                    $0.applyAnswer(id, validated, generation: provider.generation())
                }
                if validated.needsMoreSuggestions {
                    requestSuggestions(for: id, in: document, undoManager: undoManager, exclude: validated.removed)
                }
            } catch is CancellationError {
                // 끊긴 요청은 실패로 남기지 않는다.
            } catch {
                guard !Task.isCancelled, let document, Self.isCurrent(document.map[id], status: .pending, question: question) else { return }
                document.perform("Answer Failed", undoManager: undoManager) {
                    $0.failRequest(id, message: error.localizedDescription)
                }
            }
        }
        center.register(.init(id: requestID, key: key, question: question, phase: .waiting, task: task))
    }

    /// `limit`이 있으면 검증을 통과한 추가 질문 중 앞에서부터 그 개수만 쓴다.
    func requestSuggestions(for id: WID, in document: WhyNodeDocument, undoManager: UndoManager?, exclude: [String] = [], limit: Int? = nil) {
        guard let center, let node = document.map[id], node.status == .done, !suggesting.contains(id),
              let context = ContextBuilder.suggest(for: id, in: document.map, exclude: exclude)
        else { return }
        guard let provider else {
            notice = Self.notConfigured
            return
        }
        let key = AIRequestCenter.Key(document: ObjectIdentifier(document), node: id, kind: .suggest)
        guard center.request(for: key) == nil else { return }
        let question = node.question
        let requestID = UUID()
        suggesting.insert(id)
        let task = Task { [weak document] in
            defer {
                center.finish(requestID)
                suggesting.remove(id)
            }
            do {
                try await center.acquire(requestID)
                defer { center.release() }
                let response = try await measure(.suggest, context: context, document: document) {
                    try await self.retryingOnce { try await provider.suggest(context) }
                }
                guard let document, Self.isCurrent(document.map[id], status: .done, question: question) else { return }
                let (validated, _) = ResponseValidator.validate(response, for: id, in: document.map)
                let kept = limit.map { Array(validated.prefix($0)) } ?? validated
                guard !kept.isEmpty else {
                    notice = String(localized: "No new suggestions found.")
                    return
                }
                document.perform("Refresh Suggestions", undoManager: undoManager) {
                    $0.replaceSuggestions(id, with: kept)
                }
            } catch is CancellationError {
            } catch {
                // 다시 받기 실패는 노드 상태를 바꾸지 않고 알리기만 한다.
                guard !Task.isCancelled else { return }
                notice = String(localized: "Couldn't get suggestions: \(error.localizedDescription)")
            }
        }
        center.register(.init(id: requestID, key: key, question: question, phase: .waiting, task: task))
    }

    /// 문서가 바뀔 때마다 부른다. 노드가 사라졌거나(실행 취소 · 삭제), 상태가 바뀌었거나, 질문이 바뀐 요청은 끊는다.
    func reconcile(_ document: WhyNodeDocument) {
        guard let center else { return }
        for request in center.requests(in: ObjectIdentifier(document)) {
            let status: NodeStatus = request.key.kind == .answer ? .pending : .done
            if !Self.isCurrent(document.map[request.key.node], status: status, question: request.question) {
                center.cancel(request.id)
            }
        }
    }

    /// 창이 닫히면 그 문서의 요청을 모두 끊는다.
    func cancelAll(_ document: WhyNodeDocument) {
        center?.cancelAll(in: ObjectIdentifier(document))
    }

    private static func isCurrent(_ node: Node?, status: NodeStatus, question: String) -> Bool {
        guard let node else { return false }
        return node.status == status && node.question == question
    }

    /// 재시도까지 포함한 한 요청의 사용량을 모아 이번 실행 합계와 프로젝트 누적에 더한다. 실패하거나 끊겨도 보고된 만큼은 남긴다.
    private func measure<T>(_ kind: AIRequestCenter.Kind, context: ContextPackage, document: WhyNodeDocument?, _ operation: () async throws -> T) async throws -> T {
        let collector = UsageCollector()
        let started = ContinuousClock.now
        defer {
            let usage = collector.total
            center?.record(usage, kind: kind, duration: ContinuousClock.now - started, contextCharacters: Prompt.userMessage(for: context).count)
            if usage.requests > 0, let document {
                document.addUsage(usage)
            }
        }
        return try await UsageMeter.$collector.withValue(collector) { try await operation() }
    }

    /// 형식 오류는 1회 재요청한다 (SPEC 6.4-1).
    private func retryingOnce<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch is DecodingError, is ValidationError {
            return try await operation()
        } catch ProviderError.unreadableResponse, ProviderError.emptyResponse {
            return try await operation()
        }
    }
}
