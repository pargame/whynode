import SwiftUI
import UniformTypeIdentifiers
import WhyNodeCore

/// `.whynode` 문서. 디스크 쓰기는 DocumentGroup 자동 저장에 맡기고, 앱은 UndoManager로 변경만 등록한다 (SPEC 7.6).
/// `map`은 화면(메인 스레드)에서만 바뀌고, 백그라운드 저장은 `snapshot`이 넘긴 값 복사본만 읽으므로 Sendable을 직접 보증한다.
final class WhyNodeDocument: ReferenceFileDocument, @unchecked Sendable {
    typealias Snapshot = WhyNodeFile

    nonisolated static var readableContentTypes: [UTType] { [.whynode] }

    @Published private(set) var map: MindMap
    /// 열 때 무결성 규칙으로 복구한 내역 (SPEC 7.5)
    @Published var repairedIssues: [IntegrityIssue] = []
    /// 답변 요청이 진행 중인 노드. 실행 취소로 되돌린 대기 노드 중 여기에 없는 것은 중단 상태로 바꾼다.
    var inFlight: Set<WID> = []

    init(map: MindMap = .new()) {
        self.map = map
    }

    nonisolated required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let (file, issues) = Integrity.repair(try WhyNodeCodec.decode(data))
        _map = Published(initialValue: MindMap(file: file))
        _repairedIssues = Published(initialValue: issues)
    }

    func snapshot(contentType: UTType) throws -> WhyNodeFile {
        map.file
    }

    nonisolated func fileWrapper(snapshot: WhyNodeFile, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try WhyNodeCodec.encode(snapshot))
    }

    /// 변경을 적용하고 실행 취소를 등록한다. 등록이 곧 문서 변경 표시가 되어 자동 저장이 일어난다.
    func perform(_ actionName: String, undoManager: UndoManager?, _ change: (inout MindMap) -> Void) {
        let before = map
        change(&map)
        guard map != before else { return }
        registerUndo(restoring: before, actionName: actionName, undoManager: undoManager)
    }

    private func registerUndo(restoring previous: MindMap, actionName: String, undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                let current = document.map
                // 되돌린 상태의 대기 노드는 요청이 없으면 영영 기다리므로, 다시 시도할 수 있게 중단 상태로 바꾼다.
                var restored = previous
                restored.interruptPending(except: document.inFlight)
                document.map = restored
                document.registerUndo(restoring: current, actionName: actionName, undoManager: undoManager)
            }
        }
        undoManager.setActionName(actionName)
    }
}
