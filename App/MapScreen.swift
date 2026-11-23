import SwiftUI
import UniformTypeIdentifiers
import WhyNodeCore

/// 화이트보드 캔버스. 노드 표시 · 추가 질문 · 컨텍스트 메뉴 · 직접 질문 입력을 담당한다 (SPEC 2.3~2.4).
struct MapScreen: View {
    @ObservedObject var document: WhyNodeDocument
    @Environment(\.undoManager) private var undoManager
    @Environment(SettingsStore.self) private var settings

    @State private var ai = AIController()
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var panDelta: CGSize = .zero
    @GestureState private var zoomDelta: CGFloat = 1
    /// 포커스는 최대 하나이며, 포커스된 노드만 펼쳐진다.
    @State private var focusedId: WID?
    @State private var prompt: PromptRequest?
    @State private var promptText = ""
    @State private var importError: String?
    @State private var showSettings = false

    private var map: MindMap { document.map }
    private var effectiveScale: CGFloat { min(max(scale * zoomDelta, 0.2), 3) }
    private var effectiveOffset: CGSize {
        CGSize(width: offset.width + panDelta.width, height: offset.height + panDelta.height)
    }

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                Theme.canvas
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .onTapGesture { focusedId = nil }

                edges(center: center)

                ForEach(map.nodes) { node in
                    // 크기가 없는 기준점을 노드 좌표(질문의 중심)에 두고, 노드는 그 위쪽 가운데에 매단다.
                    // 펼쳐져도 위쪽 기준이 그대로라 질문이 제자리에 남는다.
                    Color.clear
                        .frame(width: 0, height: 0)
                        .overlay(alignment: .top) {
                            nodeStack(node)
                                .fixedSize()
                                .scaleEffect(effectiveScale, anchor: .top)
                                .offset(y: -NodeBubble.titleCenter * effectiveScale)
                        }
                        .position(screen(node.position, center: center))
                        .zIndex(focusedId == node.id ? 2 : 0)
                }
            }
            .gesture(zoomGesture)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: focusedId)
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
        .sheet(isPresented: $showSettings) {
            AISetupView(mode: .settings) { showSettings = false }
                .environment(settings)
        }
        .onAppear {
            updateProvider()
            if !settings.isConfigured {
                showSettings = true
            } else if map.root.status == .empty {
                ask(.root)
            }
        }
        .onChange(of: settings.ai) { updateProvider() }
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
                context.stroke(path, with: .color(Theme.edge.opacity(isDimmed(node.id) ? 0.3 : 1)), lineWidth: 1.5)
            }
            for node in map.nodes {
                for ref in node.refs {
                    guard let target = map[ref.nodeId] else { continue }
                    var path = Path()
                    path.move(to: screen(node.position, center: center))
                    path.addLine(to: screen(target.position, center: center))
                    context.stroke(path, with: .color(Theme.refEdge), style: StrokeStyle(lineWidth: 1.4, dash: [6, 5]))
                }
            }
        }
        .allowsHitTesting(false)
    }

    // 노드와 추가 질문

    /// 노드 카드와, 포커스된 경우 그 아래에 이어지는 추가 질문 칩
    private func nodeStack(_ node: Node) -> some View {
        let focused = focusedId == node.id
        return VStack(spacing: 12) {
            NodeBubble(
                node: node,
                isFocused: focused,
                isDimmed: isDimmed(node.id),
                isSuggesting: ai.suggesting.contains(node.id),
                onRetry: { retry(node.id) },
                onCustomQuestion: { ask(.custom(parent: node.id)) }
            )
            .onTapGesture { tap(node) }
            .gesture(moveGesture(for: node))
            .contextMenu { menu(for: node) }

            if focused, node.status == .done {
                suggestionChips(for: node)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func suggestionChips(for node: Node) -> some View {
        VStack(spacing: 8) {
            ForEach(node.suggestions.filter { $0.usedBy == nil }) { suggestion in
                Button {
                    pick(suggestion, of: node.id)
                } label: {
                    Text(suggestion.text)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: NodeBubble.expandedWidth - 40)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .layeredFill(Capsule(), tint: Color.accentColor.opacity(0.14))
                        .overlay(Capsule().stroke(Color.accentColor.opacity(0.6)))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 포커스 노드에 새 추가 질문이 떠 있을 때만 주변을 낮춘다 (SPEC 2.4).
    private func isDimmed(_ id: WID) -> Bool {
        guard let focusedId, focusedId != id, let focused = map[focusedId],
              focused.status == .done,
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
        // 포커스된 노드를 다시 누르면 접고, 다른 노드를 누르면 포커스를 옮긴다.
        focusedId = focusedId == node.id ? nil : node.id
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
    private func moveGesture(for node: Node) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
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
            Button { showSettings = true } label: { Label("AI 설정", systemImage: "gearshape") }
        }
    }

    private func updateProvider() {
        do {
            ai.provider = try settings.makeProvider()
        } catch {
            ai.provider = nil
            ai.notice = error.localizedDescription
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
