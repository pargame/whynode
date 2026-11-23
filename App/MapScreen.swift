import SwiftUI
import UniformTypeIdentifiers
import WhyNodeCore

/// 화이트보드 캔버스. 노드 표시 · 추가 질문 · 컨텍스트 메뉴 · 직접 질문 입력을 담당한다 (SPEC 2.3~2.4).
struct MapScreen: View {
    @ObservedObject var document: WhyNodeDocument
    @Environment(\.undoManager) private var undoManager
    @Environment(\.newDocument) private var newDocument

    @State private var ai = AIController()
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var panDelta: CGSize = .zero
    @GestureState private var zoomDelta: CGFloat = 1
    @State private var focusedId: WID?
    @State private var expanded: Set<WID> = []
    @State private var prompt: PromptRequest?
    @State private var promptText = ""
    @State private var showImporter = false
    @State private var importError: String?

    private var map: MindMap { document.map }
    private var effectiveScale: CGFloat { min(max(scale * zoomDelta, 0.2), 3) }
    private var effectiveOffset: CGSize {
        CGSize(width: offset.width + panDelta.width, height: offset.height + panDelta.height)
    }

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                Color(white: 0.97)
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .onTapGesture { focusedId = nil }

                edges(center: center)

                ForEach(map.nodes) { node in
                    NodeBubble(
                        node: node,
                        isExpanded: expanded.contains(node.id),
                        isFocused: focusedId == node.id,
                        isDimmed: isDimmed(node.id),
                        isSuggesting: ai.suggesting.contains(node.id),
                        onRetry: { retry(node.id) },
                        onCustomQuestion: { ask(.custom(parent: node.id)) }
                    )
                    .scaleEffect(effectiveScale)
                    .position(screen(node.position, center: center))
                    .onTapGesture { tap(node) }
                    .gesture(moveGesture(for: node, center: center))
                    .contextMenu { menu(for: node) }
                }

                if let focusedId, let node = map[focusedId], node.status == .done, expanded.contains(focusedId) {
                    suggestionChips(for: node, center: center)
                }
            }
            .gesture(zoomGesture)
            .animation(.easeInOut(duration: 0.25), value: focusedId)
            .animation(.easeInOut(duration: 0.25), value: expanded)
        }
        .toolbar { toolbar }
        .alert(prompt?.title ?? "", isPresented: promptBinding) {
            TextField(prompt?.placeholder ?? "", text: $promptText)
            Button("확인") { submitPrompt() }
            Button("취소", role: .cancel) { prompt = nil }
        }
        .alert("알림", isPresented: noticeBinding) {
            Button("확인", role: .cancel) { ai.notice = nil; importError = nil }
        } message: {
            Text(ai.notice ?? importError ?? "")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            importV1(result)
        }
        .onAppear {
            if map.root.status == .empty { ask(.root) }
        }
    }

    // 좌표 변환

    private func screen(_ position: Position, center: CGPoint) -> CGPoint {
        CGPoint(
            x: center.x + effectiveOffset.width + position.x * effectiveScale,
            y: center.y + effectiveOffset.height + position.y * effectiveScale
        )
    }

    // 선

    private func edges(center: CGPoint) -> some View {
        let map = map
        return Canvas { context, _ in
            for node in map.nodes {
                guard let pid = node.parentId, let parent = map[pid] else { continue }
                var path = Path()
                path.move(to: screen(parent.position, center: center))
                path.addLine(to: screen(node.position, center: center))
                context.stroke(path, with: .color(.gray.opacity(isDimmed(node.id) ? 0.15 : 0.5)), lineWidth: 1.5)
            }
            for node in map.nodes {
                for ref in node.refs {
                    guard let target = map[ref.nodeId] else { continue }
                    var path = Path()
                    path.move(to: screen(node.position, center: center))
                    path.addLine(to: screen(target.position, center: center))
                    context.stroke(path, with: .color(.indigo.opacity(0.45)), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
                }
            }
        }
        .allowsHitTesting(false)
    }

    // 추가 질문 칩: 포커스 노드 주위에 띄운다

    private func suggestionChips(for node: Node, center: CGPoint) -> some View {
        let unused = node.suggestions.filter { $0.usedBy == nil }
        let origin = screen(node.position, center: center)
        let radius = 190 * effectiveScale + 40
        return ForEach(Array(unused.enumerated()), id: \.element.id) { index, suggestion in
            let angle = -Double.pi / 2 + (Double(index) - Double(unused.count - 1) / 2) * 0.75 + .pi
            Button {
                pick(suggestion, of: node.id)
            } label: {
                Text(suggestion.text)
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: 220)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.blue.opacity(0.1), in: Capsule())
                    .overlay(Capsule().stroke(.blue.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .position(x: origin.x + cos(angle) * radius * 1.3, y: origin.y + sin(angle) * radius)
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// 포커스 노드에 새 추가 질문이 떠 있을 때만 주변을 낮춘다 (SPEC 2.4).
    private func isDimmed(_ id: WID) -> Bool {
        guard let focusedId, focusedId != id, let focused = map[focusedId],
              expanded.contains(focusedId), focused.status == .done,
              focused.suggestions.contains(where: { $0.usedBy == nil })
        else { return false }
        return true
    }

    // 동작

    private func tap(_ node: Node) {
        if node.status == .empty {
            ask(.root)
            return
        }
        focusedId = node.id
        if expanded.contains(node.id) {
            expanded.remove(node.id)
        } else {
            expanded.insert(node.id)
        }
    }

    private func pick(_ suggestion: Suggestion, of parentId: WID) {
        var created: WID?
        document.perform("추가 질문 선택", undoManager: undoManager) {
            created = $0.addChild(of: parentId, suggestion: suggestion.id)
        }
        if let created { start(created) }
    }

    private func start(_ id: WID) {
        focusedId = id
        expanded.insert(id)
        ai.requestAnswer(for: id, in: document, undoManager: undoManager)
    }

    private func retry(_ id: WID) {
        document.perform("답변 다시 받기", undoManager: undoManager) { $0.beginRegenerate(id) }
        ai.requestAnswer(for: id, in: document, undoManager: undoManager)
    }

    @ViewBuilder
    private func menu(for node: Node) -> some View {
        if node.status != .empty {
            Button("직접 질문…") { ask(.custom(parent: node.id)) }
            Button("추가 질문 다시 받기") {
                ai.requestSuggestions(for: node.id, in: document, undoManager: undoManager)
            }
            .disabled(node.status != .done)
            Button("답변 다시 받기") { retry(node.id) }
                .disabled(node.status == .pending)
            Button("질문 수정…") { ask(.edit(node.id), initial: node.question) }
        }
        if node.id != map.rootId, !map.childIDs(of: node.id).isEmpty {
            Button(node.collapsed ? "가지 펼치기" : "가지 접기") {
                document.perform(node.collapsed ? "가지 펼치기" : "가지 접기", undoManager: undoManager) {
                    $0.setCollapsed(node.id, !node.collapsed)
                }
            }
        }
        if node.id != map.rootId {
            Divider()
            Button("삭제", role: .destructive) {
                document.perform("노드 삭제", undoManager: undoManager) { $0.deleteSubtree(node.id) }
                if let focusedId, map[focusedId] == nil { self.focusedId = nil }
            }
        }
    }

    // 입력

    private func ask(_ request: PromptRequest, initial: String = "") {
        promptText = initial
        prompt = request
    }

    private func submitPrompt() {
        guard let request = prompt else { return }
        prompt = nil
        let text = promptText
        switch request {
        case .root:
            document.perform("주제 입력", undoManager: undoManager) { $0.setRootQuestion(text) }
            if map.root.status == .pending { start(map.rootId) }
        case .custom(let parent):
            var created: WID?
            document.perform("직접 질문", undoManager: undoManager) {
                created = $0.addCustomChild(of: parent, question: text)
            }
            if let created { start(created) }
        case .edit(let id):
            document.perform("질문 수정", undoManager: undoManager) { $0.editQuestion(id, to: text) }
            if map[id]?.status == .pending { start(id) }
        }
    }

    private var promptBinding: Binding<Bool> {
        Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })
    }

    private var noticeBinding: Binding<Bool> {
        Binding(get: { ai.notice != nil || importError != nil }, set: { if !$0 { ai.notice = nil; importError = nil } })
    }

    // 제스처

    private var panGesture: some Gesture {
        DragGesture()
            .updating($panDelta) { value, state, _ in state = value.translation }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($zoomDelta) { value, state, _ in state = value.magnification }
            .onEnded { value in scale = min(max(scale * value.magnification, 0.2), 3) }
    }

    /// 노드를 끌어 옮기면 자동 배치에서 제외된다. 드래그가 끝날 때 한 번만 실행 취소에 등록한다.
    private func moveGesture(for node: Node, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onEnded { value in
                let x = node.position.x + value.translation.width / effectiveScale
                let y = node.position.y + value.translation.height / effectiveScale
                document.perform("노드 이동", undoManager: undoManager) { $0.move(node.id, to: (x, y)) }
            }
    }

    // 도구 막대

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { scale = max(scale / 1.25, 0.2) } label: { Label("축소", systemImage: "minus.magnifyingglass") }
            Button { scale = min(scale * 1.25, 3) } label: { Label("확대", systemImage: "plus.magnifyingglass") }
            Button { scale = 1; offset = .zero } label: { Label("가운데로", systemImage: "scope") }
            Button { showImporter = true } label: { Label("v1 가져오기", systemImage: "square.and.arrow.down") }
        }
    }

    private func importV1(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let (map, _) = try V1Import.convert(Data(contentsOf: url))
            newDocument { WhyNodeDocument(map: map) }
        } catch {
            importError = error.localizedDescription
        }
    }
}

enum PromptRequest: Equatable {
    case root
    case custom(parent: WID)
    case edit(WID)

    var title: String {
        switch self {
        case .root: "무엇이 궁금한가요?"
        case .custom: "직접 질문"
        case .edit: "질문 수정"
        }
    }

    var placeholder: String {
        switch self {
        case .root: "주제나 질문 (예: 양자역학)"
        case .custom, .edit: "질문을 입력하세요"
        }
    }
}
