import Foundation
import WhyNodeCore
#if os(macOS)
import AppKit
#endif

/// 앱 전체의 AI 요청을 한곳에서 관리한다: 동시 요청 한도, 진행 중 요청 목록(취소용), 이번 실행의 사용량.
/// 창이 여러 개여도 한도를 함께 쓰고, 앱을 끌 때 남은 요청을 한꺼번에 끊는다.
@Observable
final class AIRequestCenter {
    enum Kind { case answer, suggest, links }
    enum Phase { case waiting, queued, running }

    struct Key: Hashable {
        let document: ObjectIdentifier
        let node: WID
        let kind: Kind
    }

    struct Request {
        let id: UUID
        let key: Key
        /// 요청을 만들 때의 질문. 노드 질문이 바뀌면 이 요청은 쓸모가 없어 끊는다.
        let question: String
        var phase: Phase
        let task: Task<Void, Never>
    }

    /// 마지막으로 끝난 요청의 요약
    struct LastRequest {
        let kind: Kind
        let usage: TokenUsage
        let duration: Duration
        /// 보낸 맥락(사용자 메시지)의 글자 수
        let contextCharacters: Int
    }

    private(set) var requests: [UUID: Request] = [:]
    /// 이번 실행 동안 쓴 사용량(모든 창 합계)
    private(set) var sessionUsage = TokenUsage.zero
    private(set) var lastRequest: LastRequest?

    /// 프로바이더 동시 요청 한도. 설정이 바뀌면 프로바이더를 만들 때 맞춘다.
    var limit = 1
    private var running = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init() {
        #if os(macOS)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelAll() }
        }
        #endif
    }

    // 목록

    func request(for key: Key) -> Request? {
        requests.values.first { $0.key == key }
    }

    func requests(in document: ObjectIdentifier) -> [Request] {
        requests.values.filter { $0.key.document == document }
    }

    func register(_ request: Request) {
        requests[request.id] = request
    }

    func finish(_ id: UUID) {
        requests[id] = nil
    }

    /// 취소를 건다. 목록에서는 작업이 실제로 끝날 때(`finish`) 빠진다.
    func cancel(_ id: UUID) {
        requests[id]?.task.cancel()
    }

    func cancelAll(in document: ObjectIdentifier) {
        requests(in: document).forEach { $0.task.cancel() }
    }

    /// 앱 종료 때 부른다. 작업 취소가 자식 프로세스(claude)를 바로 종료한다.
    func cancelAll() {
        requests.values.forEach { $0.task.cancel() }
    }

    // 동시 요청 한도

    /// 자리가 나면 바로, 없으면 대기열에서 기다린다. 기다리는 중에 취소되면 호출 없이 바로 빠진다.
    func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            requests[id]?.phase = .running
            return
        }
        requests[id]?.phase = .queued
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting.append((id, $0)) }
        } onCancel: {
            Task { @MainActor [weak self] in self?.leaveQueue(id) }
        }
        requests[id]?.phase = .running
    }

    func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            // 자리를 대기열 맨 앞에 그대로 넘긴다.
            waiting.removeFirst().continuation.resume()
        }
    }

    private func leaveQueue(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    // 사용량

    func record(_ usage: TokenUsage, kind: Kind, duration: Duration, contextCharacters: Int) {
        guard usage.requests > 0 else { return }
        sessionUsage += usage
        lastRequest = LastRequest(kind: kind, usage: usage, duration: duration, contextCharacters: contextCharacters)
    }

    // 화면용 집계

    func runningCount(in document: ObjectIdentifier) -> Int {
        requests(in: document).filter { $0.phase != .queued }.count
    }

    func queuedCount(in document: ObjectIdentifier) -> Int {
        requests(in: document).filter { $0.phase == .queued }.count
    }
}
