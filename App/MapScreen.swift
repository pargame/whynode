import SwiftUI
import UniformTypeIdentifiers
import WhyNodeCore

/// 화이트보드 캔버스. 노드 표시 · 추가 질문 · 컨텍스트 메뉴 · 직접 질문 입력을 담당한다 (SPEC 2.3~2.4).
struct MapScreen: View {
    @ObservedObject var document: WhyNodeDocument
    @Environment(\.undoManager) private var undoManager
    @Environment(SettingsStore.self) private var settings

    @State private var ai = AIController()
    /// 확정된 화면 배율 · 이동량. 제스처 중의 값은 아래 live 값에 따로 둔다.
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var livePan: CGSize = .zero
    @State private var liveZoom: CGFloat = 1
    @State private var zoomAnchor: CGPoint?
    /// 끌고 있는 노드와 화면상 이동량. 손을 떼기 전까지 노드와 선이 손가락을 따라온다.
    @State private var dragging: (id: WID, translation: CGSize)?
    @State private var viewSize: CGSize = .zero
    /// 포커스는 최대 하나이며, 포커스된 노드만 펼쳐진다.
    @State private var focusedId: WID?
    @State private var prompt: PromptRequest?
    @State private var promptText = ""
    @State private var importError: String?
    @State private var showSettings = false
    /// 물리 정리가 도는 동안의 시뮬레이션. 멈추면 결과를 문서에 한 번 반영하고 nil이 된다 (SPEC 2.6).
    @State private var simulation: ForceSimulation?
    @State private var ticker = FrameTicker()
    /// 정리 중에 잡은 노드의 시작 위치(월드 좌표)
    @State private var holdOrigin: CGPoint?

    static let minScale: CGFloat = 0.2
    static let maxScale: CGFloat = 3
    private static let focusSpring = Animation.spring(duration: 0.35, bounce: 0.15)

    private var map: MindMap { document.map }
    private var center: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }
    private var effectiveScale: CGFloat { Self.clamp(scale * liveZoom) }

    /// 핀치 중에는 손가락 아래의 지점이 그대로 있도록 이동량을 보정한다.
    private var effectiveOffset: CGSize {
        guard let anchor = zoomAnchor else {
            return CGSize(width: offset.width + livePan.width, height: offset.height + livePan.height)
        }
        let ratio = effectiveScale / scale
        return CGSize(
            width: anchor.x - center.x - (anchor.x - center.x - offset.width) * ratio,
            height: anchor.y - center.y - (anchor.y - center.y - offset.height) * ratio
        )
    }

    var body: some View {
        ZStack {
            Theme.canvas
                .contentShape(Rectangle())
                .gesture(panGesture)
                .onTapGesture { focusedId = nil }

            ForEach(edgeItems) { edge in
                EdgeShape(from: edge.from, to: edge.to)
                    .stroke(
                        edge.kind == .tree ? Theme.edge : Theme.refEdge,
                        style: StrokeStyle(lineWidth: edge.kind == .tree ? 1.5 : 1.4, dash: edge.kind == .tree ? [] : [6, 5])
                    )
                    .opacity(edge.dimmed ? 0.25 : 1)
                    .allowsHitTesting(false)
            }

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
                    .position(screenPoint(of: node))
                    .zIndex(dragging?.id == node.id ? 3 : focusedId == node.id ? 2 : 0)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            PhysicsControl(settings: physicsBinding, isRunning: simulation != nil, onToggle: togglePhysics)
                .padding(16)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewSize = $0 }
        .gesture(zoomGesture)
        .animation(Self.focusSpring, value: focusedId)
        #if os(macOS)
        .background(ScrollPanMonitor { delta in
            offset.width += delta.width
            offset.height += delta.height
        })
        #endif
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
        .onChange(of: map.nodes.count) { simulation?.sync(with: map) }
        .onDisappear { finishPhysics() }
    }

    // 좌표 변환

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, minScale), maxScale)
    }

    /// 정리 중에는 시뮬레이션 위치를, 끌고 있는 노드는 손가락 이동량만큼 더해 그린다.
    private func worldPoint(of node: Node) -> CGPoint {
        if let p = simulation?.position(of: node.id) { return CGPoint(x: p.x, y: p.y) }
        var point = CGPoint(x: node.position.x, y: node.position.y)
        if let dragging, dragging.id == node.id {
            point.x += dragging.translation.width / effectiveScale
            point.y += dragging.translation.height / effectiveScale
        }
        return point
    }

    private func screenPoint(of node: Node) -> CGPoint {
        let world = worldPoint(of: node)
        return CGPoint(
            x: center.x + effectiveOffset.width + world.x * effectiveScale,
            y: center.y + effectiveOffset.height + world.y * effectiveScale
        )
    }

    // 선

    private var edgeItems: [EdgeItem] {
        var items: [EdgeItem] = []
        for node in map.nodes {
            guard let pid = node.parentId, let parent = map[pid] else { continue }
            items.append(EdgeItem(
                id: "tree:\(node.id)", kind: .tree,
                from: screenPoint(of: parent), to: screenPoint(of: node),
                dimmed: isDimmed(node.id) && isDimmed(pid)
            ))
        }
        for node in map.nodes {
            for ref in node.refs {
                guard let target = map[ref.nodeId] else { continue }
                items.append(EdgeItem(
                    id: "ref:\(node.id):\(ref.nodeId)", kind: .ref,
                    from: screenPoint(of: node), to: screenPoint(of: target),
                    dimmed: isDimmed(node.id) && isDimmed(target.id)
                ))
            }
        }
        return items
    }

    // 노드와 추가 질문

    /// 노드 카드와, 포커스된 경우 그 아래에 이어지는 추가 질문 칩
    private func nodeStack(_ node: Node) -> some View {
        let focused = focusedId == node.id
        let isDragging = dragging?.id == node.id
        return VStack(spacing: 12) {
            NodeBubble(
                node: node,
                isFocused: focused,
                isDimmed: isDimmed(node.id),
                isSuggesting: ai.suggesting.contains(node.id),
                onRetry: { retry(node.id) }
            )
            .scaleEffect(isDragging ? 1.04 : 1)
            .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 16, y: 8)
            .animation(.spring(duration: 0.3, bounce: 0.3), value: isDragging)
            .onTapGesture { tap(node) }
            .gesture(moveGesture(for: node))
            .contextMenu { menu(for: node) }

            if focused, node.status == .done {
                suggestionChips(for: node)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// AI가 만든 추가 질문 아래에 같은 모양의 직접 질문 칩을 둔다.
    private func suggestionChips(for node: Node) -> some View {
        VStack(spacing: 8) {
            ForEach(node.suggestions.filter { $0.usedBy == nil }) { suggestion in
                chip(Text(suggestion.text)) { pick(suggestion, of: node.id) }
            }
            chip(Text("\(Image(systemName: "plus.bubble"))  직접 질문…").foregroundStyle(.secondary)) {
                ask(.custom(parent: node.id))
            }
        }
    }

    private func chip(_ label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .font(.callout)
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
        // 정리 중에는 노드가 펼쳐지면 배치가 흐트러지므로 포커스를 주지 않는다.
        guard simulation == nil else { return }
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
            withAnimation(Self.focusSpring) {
                document.perform("직접 질문", undoManager: undoManager) {
                    created = $0.addCustomChild(of: parent, question: text)
                }
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

    /// 캔버스 끌기. 손을 떼면 빠르기만큼 더 미끄러지다 멈춘다.
    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in livePan = value.translation }
            .onEnded { value in
                withoutAnimation {
                    offset.width += value.translation.width
                    offset.height += value.translation.height
                    livePan = .zero
                }
                let glide = CGSize(
                    width: value.predictedEndTranslation.width - value.translation.width,
                    height: value.predictedEndTranslation.height - value.translation.height
                )
                withAnimation(.smooth(duration: 0.6)) {
                    offset.width += glide.width
                    offset.height += glide.height
                }
            }
    }

    /// 핀치 확대 · 축소. 손가락 아래 지점을 기준으로 커지고 작아진다.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomAnchor == nil { zoomAnchor = value.startLocation }
                liveZoom = value.magnification
            }
            .onEnded { _ in
                withoutAnimation {
                    let settledOffset = effectiveOffset
                    scale = effectiveScale
                    offset = settledOffset
                    liveZoom = 1
                    zoomAnchor = nil
                }
            }
    }

    /// 노드 끌기. 끄는 동안 노드와 선이 따라오고, 놓는 순간 그 자리에 확정된다. 실행 취소는 놓을 때 한 번만 등록한다.
    private func moveGesture(for node: Node) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                withoutAnimation { dragging = (node.id, value.translation) }
                // 정리 중에는 잡은 노드를 손가락 위치에 고정하고, 이어진 노드가 딸려 오게 한다.
                guard simulation != nil else { return }
                if holdOrigin == nil { holdOrigin = worldPoint(of: node) }
                if let origin = holdOrigin {
                    simulation?.hold(node.id, at: (
                        origin.x + value.translation.width / effectiveScale,
                        origin.y + value.translation.height / effectiveScale
                    ))
                    simulation?.reheat(to: 0.3)
                }
            }
            .onEnded { value in
                if simulation != nil {
                    simulation?.release(node.id)
                    simulation?.reheat(to: 0.3)
                    holdOrigin = nil
                    withoutAnimation { dragging = nil }
                    return
                }
                let x = node.position.x + value.translation.width / effectiveScale
                let y = node.position.y + value.translation.height / effectiveScale
                withoutAnimation {
                    document.perform("노드 이동", undoManager: undoManager) { $0.move(node.id, to: (x, y)) }
                    dragging = nil
                }
            }
    }

    // 물리 정리

    private var physicsBinding: Binding<PhysicsSettings> {
        // 설정은 앱 전체가 공유하므로, 다른 창이 아닌 조작한 창에서만 정리를 돌린다.
        Binding(get: { settings.physics }, set: {
            settings.physics = $0
            physicsChanged()
        })
    }

    private func togglePhysics() {
        if simulation == nil { startPhysics() } else { finishPhysics() }
    }

    /// 포커스를 먼저 풀어 모든 노드를 원으로 접은 뒤 시작한다.
    private func startPhysics() {
        guard map.nodes.count > 1 else { return }
        focusedId = nil
        simulation = ForceSimulation(map: map, settings: settings.physics)
        ticker.start { stepPhysics() }
    }

    private func stepPhysics() {
        guard simulation != nil else { return ticker.stop() }
        var still = false
        withoutAnimation { still = simulation?.tick() ?? false }
        // 잡고 있는 동안에는 멈추지 않는다.
        if !still, holdOrigin == nil { finishPhysics() }
    }

    /// 멈춘 자리를 실행 취소 1회로 문서에 반영한다.
    private func finishPhysics() {
        ticker.stop()
        guard let positions = simulation?.positions else { return }
        withoutAnimation {
            document.perform("물리 정리", undoManager: undoManager) { $0.arrange(positions) }
            simulation = nil
            holdOrigin = nil
        }
    }

    /// 조절값을 바꾸면 결과가 바로 보이도록, 도는 중이면 다시 데우고 멈춰 있으면 시작한다.
    private func physicsChanged() {
        if simulation == nil {
            startPhysics()
        } else {
            simulation?.settings = settings.physics.clamped
            simulation?.reheat(to: 0.5)
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
            if let newScale { scale = Self.clamp(newScale) }
            if let newOffset { offset = newOffset }
        }
    }

    // 도구 막대

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { animateCamera(scale: scale / 1.25) } label: { Label("축소", systemImage: "minus.magnifyingglass") }
            Button { animateCamera(scale: scale * 1.25) } label: { Label("확대", systemImage: "plus.magnifyingglass") }
            Button { animateCamera(scale: 1, offset: .zero) } label: { Label("가운데로", systemImage: "scope") }
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
