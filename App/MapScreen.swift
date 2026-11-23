import SwiftUI
import UniformTypeIdentifiers
import WhyNodeCore

/// 화이트보드 캔버스. 노드 표시 · 추가 질문 · 컨텍스트 메뉴 · 직접 질문 입력을 담당한다 (SPEC 2.3~2.4).
/// 매 프레임 바뀌는 카메라 · 끌기 · 시뮬레이션 값은 `CanvasModel`에 두고, 이 화면의 body에서는 읽지 않는다.
struct MapScreen: View {
    @ObservedObject var document: WhyNodeDocument
    @Environment(\.undoManager) private var undoManager
    @Environment(SettingsStore.self) private var settings

    @State private var ai = AIController()
    @State private var canvas = CanvasModel()
    /// 포커스는 최대 하나이며, 포커스된 노드만 펼쳐진다.
    @State private var focusedId: WID?
    @State private var prompt: PromptRequest?
    @State private var promptText = ""
    @State private var importError: String?
    @State private var showSettings = false
    @State private var ticker = FrameTicker()

    private static let focusSpring = Animation.spring(duration: 0.35, bounce: 0.15)

    private var map: MindMap { document.map }

    var body: some View {
        ZStack {
            Theme.canvas
                .contentShape(Rectangle())
                .gesture(panGesture)
                .onTapGesture { focusedId = nil }

            EdgeLayer(map: map, canvas: canvas, isDimmed: isDimmed)

            NodeLayer(nodes: map.nodes, canvas: canvas, focusedId: focusedId) { node in
                nodeStack(node)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            PhysicsControl(settings: physicsBinding, isRunning: canvas.isRunning, onToggle: togglePhysics)
                .padding(16)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvas.viewSize = $0 }
        .gesture(zoomGesture)
        .animation(Self.focusSpring, value: focusedId)
        #if os(macOS)
        .background(ScrollPanMonitor { [canvas] delta in
            canvas.offset.width += delta.width
            canvas.offset.height += delta.height
        })
        .background(DeleteKeyMonitor { deleteFocused() })
        #endif
        .toolbar { toolbar }
        .alert(prompt?.title ?? "", isPresented: promptBinding) {
            TextField(prompt?.placeholder ?? "", text: $promptText)
            Button("확인") { submitPrompt() }
            Button("취소", role: .cancel) { prompt = nil }
        } message: {
            if case .edit(let id) = prompt, !map.childIDs(of: id).isEmpty {
                Text("답변은 새로 받고, 하위 노드는 유지됩니다.")
            }
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
        .focusedSceneValue(\.resetFocusedNodeTextScale, focusedNodeHasTextScale ? { resetTextScale(focusedId) } : nil)
        .onChange(of: settings.ai) { updateProvider() }
        .onChange(of: map.nodes.count) { canvas.simulation?.sync(with: map) }
        .onDisappear { finishPhysics() }
    }

    // 노드와 추가 질문

    /// 노드 카드와, 포커스된 경우 그 아래에 이어지는 추가 질문 칩
    private func nodeStack(_ node: Node) -> some View {
        let focused = focusedId == node.id
        let isDragging = canvas.dragging?.id == node.id
        let textScale = settings.textScale * canvas.textScale(of: node)
        return VStack(spacing: 12) {
            NodeBubble(
                node: node,
                isFocused: focused,
                isDimmed: isDimmed(node.id),
                isSuggesting: ai.suggesting.contains(node.id),
                isQuiet: canvas.isMoving,
                textScale: textScale,
                zoom: canvas.effectiveScale,
                isHighlighted: isHighlighted(node.id),
                onRetry: { retry(node.id) }
            )
            .equatable()
            .scaleEffect(isDragging ? 1.04 : 1)
            .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 16, y: 8)
            .animation(.spring(duration: 0.3, bounce: 0.3), value: isDragging)
            .onHover { inside in hover(node.id, inside) }
            .onTapGesture { tap(node) }
            .gesture(moveGesture(for: node))
            .contextMenu { menu(for: node) }

            if focused, node.status == .done {
                suggestionChips(for: node, textScale: textScale, zoom: canvas.effectiveScale)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // 펼친 노드 위에서의 핀치는 화면 확대 대신 이 노드의 글자 크기를 바꾼다. 노드 크기는 그대로다.
        .gesture(textPinchGesture(for: node), including: focused ? .all : .subviews)
    }

    private var focusedNodeHasTextScale: Bool {
        focusedId.flatMap { map[$0] }.map { $0.textScale != 1 } ?? false
    }

    private func resetTextScale(_ id: WID?) {
        guard let id else { return }
        document.perform("글자 크기 원래대로", undoManager: undoManager) { $0.setTextScale(id, 1) }
    }

    private func textPinchGesture(for node: Node) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                withoutAnimation { canvas.textPinch = (node.id, value.magnification) }
            }
            .onEnded { value in
                let target = node.textScale * value.magnification
                withoutAnimation {
                    document.perform("글자 크기", undoManager: undoManager) { $0.setTextScale(node.id, target) }
                    canvas.textPinch = nil
                }
            }
    }

    /// AI가 만든 추가 질문 아래에 같은 모양의 직접 질문 칩을 둔다.
    private static let chipSpacing: CGFloat = 8
    private static let chipPadding: CGFloat = 14
    /// 추가 질문 칩 글자 영역의 최대 폭. 마지막 줄의 반쪽 칩 두 개를 합친 폭과 같다.
    private static let chipTextMaxWidth = NodeBubble.expandedWidth - 40
    private static let halfChipTextWidth = (chipTextMaxWidth + 2 * chipPadding - chipSpacing) / 2 - 2 * chipPadding

    /// 추가 질문은 한 줄에 하나씩, 맨 아래 줄만 `직접 질문…`과 `다른 질문 3개`로 반씩 나눈다 (SPEC 2.3).
    private func suggestionChips(for node: Node, textScale: Double, zoom: CGFloat) -> some View {
        VStack(spacing: Self.chipSpacing) {
            ForEach(node.suggestions.filter { $0.usedBy == nil }) { suggestion in
                chip(Text(suggestion.text), textScale: textScale, zoom: zoom) { pick(suggestion, of: node.id) }
            }
            let suggesting = ai.suggesting.contains(node.id)
            HStack(spacing: Self.chipSpacing) {
                chip(Text("\(Image(systemName: "plus.bubble"))  직접 질문…").foregroundStyle(.secondary), textScale: textScale, zoom: zoom, width: Self.halfChipTextWidth) {
                    ask(.custom(parent: node.id))
                }
                chip(Text("\(Image(systemName: "arrow.clockwise"))  다른 질문 3개").foregroundStyle(.secondary), textScale: textScale, zoom: zoom, width: Self.halfChipTextWidth) {
                    ai.requestSuggestions(for: node.id, in: document, undoManager: undoManager, limit: 3)
                }
                .disabled(suggesting)
                .opacity(suggesting ? 0.5 : 1)
            }
        }
    }

    /// `width`가 없으면 글자 길이에 맞춰 최대 폭까지 늘어나고, 있으면 그 폭으로 고정한다.
    private func chip(_ label: Text, textScale: Double, zoom: CGFloat, width: CGFloat? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .font(.scaled(.callout, textScale))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: width)
                .frame(maxWidth: width == nil ? Self.chipTextMaxWidth : nil)
                .padding(.horizontal, Self.chipPadding)
                .padding(.vertical, 9)
                .layeredFill(Capsule(), tint: Color.accentColor.opacity(0.14))
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.6), lineWidth: 1 / zoom))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
    }

    /// 호버한 노드 자신과, 트리 선 · 참조선으로 바로 이어진 노드
    private func isHighlighted(_ id: WID) -> Bool {
        guard let hoveredId = canvas.hoveredId, let hovered = map[hoveredId], let node = map[id] else { return false }
        return id == hoveredId || node.parentId == hoveredId || hovered.parentId == id
            || node.refs.contains { $0.nodeId == hoveredId } || hovered.refs.contains { $0.nodeId == id }
    }

    /// 빛은 갑자기 켜지지 않고 0.5초 안에 은은하게 밝아지고 옅어진다.
    private func hover(_ id: WID, _ inside: Bool) {
        withAnimation(Theme.glowAnimation) {
            if inside {
                canvas.hoveredId = id
            } else if canvas.hoveredId == id {
                canvas.hoveredId = nil
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
        // 시뮬레이션 중에는 노드가 펼쳐지면 배치가 흐트러지므로 포커스를 주지 않는다.
        guard !canvas.isRunning else { return }
        if node.status == .empty {
            ask(.root)
            return
        }
        // 포커스된 노드를 다시 누르면 접고, 다른 노드를 누르면 포커스를 옮긴다.
        focusedId = focusedId == node.id ? nil : node.id
    }

    private func pick(_ suggestion: Suggestion, of parentId: WID) {
        var created: WID?
        withAnimation(Self.focusSpring) {
            document.perform("추가 질문 선택", undoManager: undoManager) {
                created = $0.addChild(of: parentId, suggestion: suggestion.id)
            }
        }
        // 포커스를 부모에 그대로 두어 남은 추가 질문을 이어서 고를 수 있게 한다.
        if let created { start(created, focus: false) }
    }

    private func start(_ id: WID, focus: Bool = true) {
        if focus { focusedId = id }
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
        if node.textScale != 1 {
            Button("글자 크기 원래대로") { resetTextScale(node.id) }
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

    /// ⌫ · ⌦: 포커스 노드와 그 아래 가지를 확인 없이 지운다. ⌘Z로 되돌린다. 루트는 지우지 않는다.
    private func deleteFocused() -> Bool {
        guard let id = focusedId, id != map.rootId, map[id] != nil else { return false }
        document.perform("노드 삭제", undoManager: undoManager) { $0.deleteSubtree(id) }
        focusedId = nil
        return true
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
            withAnimation(Self.focusSpring) {
                document.perform("직접 질문", undoManager: undoManager) {
                    created = $0.addCustomChild(of: parent, question: text)
                }
            }
            if let created { start(created, focus: false) }
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

    /// 캔버스 끌기. 손을 떼면 빠르기만큼 더 미끄러지다 멈춘다.
    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { [canvas] value in canvas.livePan = value.translation }
            .onEnded { [canvas] value in
                withoutAnimation {
                    canvas.offset.width += value.translation.width
                    canvas.offset.height += value.translation.height
                    canvas.livePan = .zero
                }
                let glide = CGSize(
                    width: value.predictedEndTranslation.width - value.translation.width,
                    height: value.predictedEndTranslation.height - value.translation.height
                )
                withAnimation(.smooth(duration: 0.6)) {
                    canvas.offset.width += glide.width
                    canvas.offset.height += glide.height
                }
            }
    }

    /// 핀치 확대 · 축소. 손가락 아래 지점을 기준으로 커지고 작아진다.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { [canvas] value in
                if canvas.zoomAnchor == nil { canvas.zoomAnchor = value.startLocation }
                canvas.liveZoom = value.magnification
            }
            .onEnded { [canvas] _ in
                withoutAnimation {
                    let settledOffset = canvas.effectiveOffset
                    canvas.scale = canvas.effectiveScale
                    canvas.offset = settledOffset
                    canvas.liveZoom = 1
                    canvas.zoomAnchor = nil
                }
            }
    }

    /// 노드 끌기. 끄는 동안 노드와 선이 따라오고, 놓는 순간 그 자리에 확정된다. 실행 취소는 놓을 때 한 번만 등록한다.
    private func moveGesture(for node: Node) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                withoutAnimation { canvas.dragging = (node.id, value.translation) }
                // 시뮬레이션 중에는 잡은 노드를 손가락 위치에 고정하고, 이어진 노드가 딸려 오게 한다.
                guard canvas.simulation != nil else { return }
                if canvas.holdOrigin == nil { canvas.holdOrigin = canvas.worldPoint(of: node) }
                if let origin = canvas.holdOrigin {
                    let scale = canvas.effectiveScale
                    canvas.simulation?.hold(node.id, at: (
                        origin.x + value.translation.width / scale,
                        origin.y + value.translation.height / scale
                    ))
                    canvas.simulation?.reheat(to: 0.3)
                }
            }
            .onEnded { value in
                if canvas.simulation != nil {
                    canvas.simulation?.release(node.id)
                    canvas.simulation?.reheat(to: 0.3)
                    canvas.holdOrigin = nil
                    withoutAnimation { canvas.dragging = nil }
                    return
                }
                let x = node.position.x + value.translation.width / canvas.effectiveScale
                let y = node.position.y + value.translation.height / canvas.effectiveScale
                withoutAnimation {
                    document.perform("노드 이동", undoManager: undoManager) { $0.move(node.id, to: (x, y)) }
                    canvas.dragging = nil
                }
            }
    }

    // 시뮬레이션

    private var physicsBinding: Binding<PhysicsSettings> {
        // 설정은 앱 전체가 공유하므로, 다른 창이 아닌 조작한 창에서만 시뮬레이션을 돌린다.
        Binding(get: { settings.physics }, set: {
            settings.physics = $0
            physicsChanged()
        })
    }

    private func togglePhysics() {
        if canvas.isRunning { finishPhysics() } else { startPhysics() }
    }

    /// 포커스를 먼저 풀어 모든 노드를 원으로 접은 뒤 시작한다.
    private func startPhysics() {
        guard map.nodes.count > 1 else { return }
        focusedId = nil
        canvas.startSimulation(ForceSimulation(map: map, settings: settings.physics))
        ticker.start { stepPhysics() }
    }

    private func stepPhysics() {
        guard canvas.simulation != nil else { return ticker.stop() }
        var still = false
        withoutAnimation { still = canvas.simulation?.tick() ?? false }
        // 잡고 있는 동안에는 멈추지 않는다.
        if !still, canvas.holdOrigin == nil { finishPhysics() }
    }

    /// 멈춘 자리를 실행 취소 1회로 문서에 반영한다.
    private func finishPhysics() {
        ticker.stop()
        guard canvas.simulation != nil else { return }
        withoutAnimation {
            guard let positions = canvas.stopSimulation() else { return }
            document.perform("시뮬레이션", undoManager: undoManager) { $0.arrange(positions) }
        }
    }

    /// 조절값을 바꾸면 결과가 바로 보이도록, 도는 중이면 다시 데우고 멈춰 있으면 시작한다.
    private func physicsChanged() {
        if canvas.simulation == nil {
            startPhysics()
        } else {
            canvas.simulation?.settings = settings.physics.clamped
            canvas.simulation?.reheat(to: 0.5)
        }
    }

    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    /// 버튼으로 바꾸는 배율 · 위치는 부드럽게 옮긴다.
    private func animateCamera(scale newScale: CGFloat? = nil, offset newOffset: CGSize? = nil) {
        withAnimation(.smooth(duration: 0.35)) {
            if let newScale { canvas.scale = CanvasModel.clamp(newScale) }
            if let newOffset { canvas.offset = newOffset }
        }
    }

    // 도구 막대

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { animateCamera(scale: canvas.scale / 1.25) } label: { Label("축소", systemImage: "minus.magnifyingglass") }
            Button { animateCamera(scale: canvas.scale * 1.25) } label: { Label("확대", systemImage: "plus.magnifyingglass") }
            Button { animateCamera(scale: 1, offset: .zero) } label: { Label("가운데로", systemImage: "scope") }
            Button { settings.stepTextScale(-1) } label: { Label("글자 작게", systemImage: "textformat.size.smaller") }
                .disabled(settings.textScale <= SettingsStore.textScaleRange.lowerBound)
            Button { settings.stepTextScale(1) } label: { Label("글자 크게", systemImage: "textformat.size.larger") }
                .disabled(settings.textScale >= SettingsStore.textScaleRange.upperBound)
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
