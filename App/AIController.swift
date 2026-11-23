import SwiftUI
import WhyNodeCore

/// 노드 답변 · 추가 질문 요청을 프로바이더에 보내고 결과를 검증해 문서에 반영한다 (SPEC 5.3, 6.4).
@Observable
final class AIController {
    var provider: any AIProvider = MockProvider()
    /// 추가 질문 다시 받기 중인 노드. 노드 상태(`status`)와 별개인 화면 전용 로딩 상태다.
    private(set) var suggesting: Set<WID> = []
    var notice: String?

    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func requestAnswer(for id: WID, in document: WhyNodeDocument, undoManager: UndoManager?) {
        guard let context = ContextBuilder.answer(for: id, in: document.map) else { return }
        let provider = provider
        Task {
            await acquire()
            defer { release() }
            do {
                let validated = try await retryingOnce {
                    let response = try await provider.answer(context)
                    return try ResponseValidator.validate(response, for: id, in: document.map)
                }
                document.perform("답변 받기", undoManager: undoManager) {
                    $0.applyAnswer(id, validated, generation: provider.generation())
                }
                if validated.needsMoreSuggestions {
                    requestSuggestions(for: id, in: document, undoManager: undoManager, exclude: validated.removed)
                }
            } catch {
                document.perform("답변 실패", undoManager: undoManager) {
                    $0.failRequest(id, message: error.localizedDescription)
                }
            }
        }
    }

    func requestSuggestions(for id: WID, in document: WhyNodeDocument, undoManager: UndoManager?, exclude: [String] = []) {
        guard !suggesting.contains(id),
              let context = ContextBuilder.suggest(for: id, in: document.map, exclude: exclude)
        else { return }
        suggesting.insert(id)
        let provider = provider
        Task {
            await acquire()
            defer {
                release()
                suggesting.remove(id)
            }
            do {
                let response = try await retryingOnce { try await provider.suggest(context) }
                let (kept, _) = ResponseValidator.validate(response, for: id, in: document.map)
                guard !kept.isEmpty else {
                    notice = "새로운 추가 질문을 찾지 못했습니다."
                    return
                }
                document.perform("추가 질문 다시 받기", undoManager: undoManager) {
                    $0.replaceSuggestions(id, with: kept)
                }
            } catch {
                // 다시 받기 실패는 노드 상태를 바꾸지 않고 알리기만 한다.
                notice = "추가 질문을 받지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    /// 형식 오류는 1회 재요청한다 (SPEC 6.4-1).
    private func retryingOnce<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch is DecodingError, is ValidationError {
            return try await operation()
        }
    }

    // 프로바이더 동시 요청 한도

    private func acquire() async {
        if running < provider.capabilities.maxConcurrentRequests {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
