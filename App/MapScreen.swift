import SwiftUI
import UniformTypeIdentifiers
import WhyNodeCore

/// 화이트보드 캔버스. 노드 표시 · 추가 질문 · 컨텍스트 메뉴 · 직접 질문 입력을 담당한다 (SPEC 2.3~2.4).
/// 매 프레임 바뀌는 카메라 · 끌기 · 시뮬레이션 값은 `CanvasModel`에 두고, 이 화면의 body에서는 읽지 않는다.
struct MapScreen: View {
    @ObservedObject var document: WhyNodeDocument
    @Environment(\.undoManager) private var undoManager
    @Environment(SettingsStore.self) private var settings
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var ai = AIController()
    @State private var canvas = CanvasModel()
    /// 포커스는 최대 하나이며, 포커스된 노드만 펼쳐진다.
    @State private var focusedId: WID?
    /// 직접 질문 입력란이 열린 노드와 입력 중인 글
    @State private var composingFor: WID?
    /// 우클릭한 노드의 편집 패널과 그 위치(캔버스 좌표)
    @State private var styleTarget: StyleTarget?
    @State private var stylePanelSize = CGSize(width: 320, height: 260)
    /// 패널이 열린 동안의 편집은 실행 취소 한 번으로 묶는다(연타 · 색 끌기).
    @State private var styleUndoRegistered = false
    @State private var composeText = ""
    @FocusState private var composeFocused: Bool
    @State private var prompt: PromptRequest?
    @State private var promptText = ""
    @State private var importError: String?
    @State private var showSettings = false
    @State private var ticker = FrameTicker()

    private static let focusSpring = Animation.spring(duration: 0.35, bounce: 0.15)

    private var map: MindMap { document.map }

    var body: some View {
        observed(presented(canvasArea))
    }

    /// 캔버스 · 노드 · 떠 있는 막대 · 패널과 입력 처리
    private var canvasArea: some View {
        ZStack {
            Theme.canvas
                .contentShape(Rectangle())
                .gesture(panGesture)
                .onTapGesture {
                    focusedId = nil
                    closeStylePanel()
                }

            EdgeLayer(map: map, canvas: canvas, isDimmed: isDimmed)

            NodeLayer(nodes: map.nodes, canvas: canvas, focusedId: focusedId) { node in
                nodeStack(node)
            }
        }
        .overlay(alignment: .bottomLeading) {
            AIStatusBar(center: settings.requests, document: ObjectIdentifier(document), projectUsage: map.file.project.usage, connection: settings.ai?.summary)
                .padding(16)
        }
        .overlay(alignment: .bottomTrailing) {
            PhysicsControl(settings: physicsBinding, isRunning: canvas.isRunning, onToggle: togglePhysics)
                .padding(16)
        }
        .overlay { stylePanel }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvas.viewSize = $0 }
        .gesture(zoomGesture)
        .animation(Self.focusSpring, value: focusedId)
        #if os(macOS)
        .background(ScrollPanMonitor { delta in
            closeStylePanel()
            canvas.offset.width += delta.width
            canvas.offset.height += delta.height
        })
        .background(CanvasEventMonitor(
            onDelete: { deleteFocused() },
            onEscape: {
                guard styleTarget != nil else { return false }
                closeStylePanel()
                return true
            },
            onSecondaryClick: { openStylePanel(at: $0) }
        ))
        .background(WindowReader { [canvas] in canvas.window = $0 })
        #endif
    }

    /// 도구 막대 · 알림 · 시트 · 메뉴 상태
    private func presented(_ content: some View) -> some View {
        content
        .toolbar { toolbar }
        .alert(prompt?.title ?? "", isPresented: promptBinding) {
            TextField(prompt?.placeholder ?? "", text: $promptText)
            Button("OK") { submitPrompt() }
            Button("Cancel", role: .cancel) { prompt = nil }
        }
        .alert("Notice", isPresented: noticeBinding) {
            Button("OK", role: .cancel) { ai.notice = nil; importError = nil }
        } message: {
            Text(ai.notice ?? importError ?? "")
        }
        .sheet(isPresented: $showSettings) {
            AISetupView(mode: .settings) { showSettings = false }
                .environment(settings)
        }
        .onAppear {
            ai.center = settings.requests
            document.markEdited = { markDocumentEdited() }
            updateProvider()
            if !settings.isConfigured {
                showSettings = true
            } else if map.root.status == .empty {
                ask(.root)
            }
        }
        .focusedSceneValue(\.documentUndo, DocumentUndoState(
            busy: !settings.requests.requests(in: ObjectIdentifier(document)).isEmpty,
            undoTitle: undoManager?.canUndo == true ? undoManager?.undoMenuItemTitle : nil,
            redoTitle: undoManager?.canRedo == true ? undoManager?.redoMenuItemTitle : nil
        ))
        .focusedSceneValue(\.resetFocusedNodeTextScale, focusedNodeHasTextScale ? { resetTextScale(focusedId) } : nil)
    }

    /// 설정 · 문서 · 실행 취소 · 포커스 변화에 반응
    private func observed(_ content: some View) -> some View {
        content
        .onChange(of: settings.ai) { updateProvider() }
        // 실행 취소 · 삭제 · 질문 수정으로 쓸모가 없어진 요청은 바로 끊는다.
        .onChange(of: document.map) {
            ai.reconcile(document)
            // 실행 취소 · 삭제로 편집 중이던 노드가 사라지면 패널을 닫는다.
            if let styleTarget, map[styleTarget.id] == nil { closeStylePanel() }
        }
        // 패널이 열린 채 실행 취소 · 다시 실행하면 다음 편집은 새 실행 취소 단계로 쌓는다.
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { note in
            if (note.object as? UndoManager) === undoManager { styleUndoRegistered = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { note in
            if (note.object as? UndoManager) === undoManager { styleUndoRegistered = false }
        }
        .onChange(of: map.nodes.count) { old, new in
            // 자동 정리 중에 실행 취소 · 삭제로 노드가 줄면, 되돌린 문서에 정리 좌표를 덮어쓰지 않도록 결과 없이 멈춘다.
            if new < old, canvas.isSimulating, !canvas.isRunning {
                cancelAutoArrange()
            } else {
                canvas.simulation?.sync(with: map)
            }
        }
        // 핀치 도중 포커스가 바뀌면 제스처가 끝 신호 없이 취소될 수 있어 핀치 중 값을 비운다.
        .onChange(of: focusedId) {
            canvas.textPinch = nil
            if composingFor != nil, composingFor != focusedId { cancelCompose() }
        }
        // 직접 질문 입력란에서 빠져나갔는데 쓴 글이 없으면 닫는다.
        .onChange(of: composeFocused) { if !composeFocused, composeText.isEmpty, composingFor != nil { cancelCompose() } }
        .onDisappear {
            finishPhysics()
            ai.cancelAll(document)
        }
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
        document.perform("Reset Text Size", undoManager: undoManager) { $0.setTextScale(id, 1) }
    }

    private func textPinchGesture(for node: Node) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                withoutAnimation { canvas.textPinch = (node.id, value.magnification) }
            }
            .onEnded { value in
                let target = node.textScale * value.magnification
                withoutAnimation {
                    document.perform("Text Size", undoManager: undoManager) { $0.setTextScale(node.id, target) }
                    canvas.textPinch = nil
                }
            }
    }

    /// AI가 만든 추가 질문 아래에 같은 모양의 직접 질문 칩을 둔다.
    static let chipSpacing: CGFloat = 8
    static let chipPadding: CGFloat = 14
    /// 추가 질문 칩 글자 영역의 최대 폭. 맨 아래 줄 반쪽 칩 두 개를 합친 폭과 같다.
    /// 칩 폭은 노드 크기를 따라 펼친 카드 폭에 맞춘다.
    private struct ChipMetrics {
        let textMaxWidth: CGFloat
        let rowWidth: CGFloat
        let halfTextWidth: CGFloat

        init(size: CGFloat) {
            textMaxWidth = NodeBubble.expandedWidth * size - 40
            rowWidth = textMaxWidth + 2 * MapScreen.chipPadding
            halfTextWidth = (rowWidth - MapScreen.chipSpacing) / 2 - 2 * MapScreen.chipPadding
        }
    }
    /// 이보다 많으면 추가 질문 목록을 스크롤한다.
    private static let maxVisibleChips = 6

    /// 추가 질문은 한 줄에 하나씩(많으면 스크롤), 맨 아래 줄만 `직접 질문`과 `다른 질문 3개`로 반씩 나눈다 (SPEC 2.3).
    private func suggestionChips(for node: Node, textScale: Double, zoom: CGFloat) -> some View {
        let open = node.suggestions.filter { $0.usedBy == nil }
        return VStack(spacing: Self.chipSpacing) {
            ChipList(count: open.count, maxVisible: Self.maxVisibleChips, spacing: Self.chipSpacing) {
                ForEach(open) { suggestion in
                    chip(Text(suggestion.text), textScale: textScale, zoom: zoom, metrics: ChipMetrics(size: node.sizeScale)) { pick(suggestion, of: node.id) }
                }
            }
            bottomRow(for: node, textScale: textScale, zoom: zoom)
        }
    }

    /// `직접 질문`을 누르면 그 칩이 줄 전체로 넓어지며 입력란이 되고, `다른 질문 3개`는 오른쪽으로 밀려 사라진다.
    private func bottomRow(for node: Node, textScale: Double, zoom: CGFloat) -> some View {
        let metrics = ChipMetrics(size: node.sizeScale)
        let composing = composingFor == node.id
        let suggesting = ai.suggesting.contains(node.id)
        let full = node.suggestions.filter { $0.usedBy == nil }.count >= MindMap.maxOpenSuggestions
        return HStack(spacing: Self.chipSpacing) {
            Group {
                if composing {
                    HStack(spacing: 8) {
                        TextField("Ask your own question", text: $composeText)
                            .textFieldStyle(.plain)
                            .focused($composeFocused)
                            .onSubmit { submitCompose(parent: node.id) }
                            #if os(macOS)
                            .onExitCommand { cancelCompose() }
                            #endif
                        Button { submitCompose(parent: node.id) } label: { Image(systemName: "arrow.up.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .disabled(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    (Text(Image(systemName: "plus.bubble")) + Text(verbatim: "  ") + Text("Ask Your Own"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                }
            }
            .font(.scaled(.callout, textScale))
            .frame(width: composing ? metrics.rowWidth - 2 * Self.chipPadding : metrics.halfTextWidth)
            .padding(.horizontal, Self.chipPadding)
            .padding(.vertical, 9)
            .layeredFill(Capsule(), tint: Color.accentColor.opacity(composing ? 0.06 : 0.14))
            .overlay(Capsule().stroke(Color.accentColor.opacity(0.6), lineWidth: (composing ? 1.5 : 1) / zoom))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
            .contentShape(Capsule())
            .onTapGesture { if !composing { startCompose(node.id) } }

            if !composing {
                // 미사용 추가 질문이 최대 개수면 더 받지 않는다(오래된 질문을 몰래 지우지 않는다).
                chip((full ? Text("Up to \(MindMap.maxOpenSuggestions) questions") : Text(Image(systemName: "arrow.clockwise")) + Text(verbatim: "  ") + Text("3 Other Questions")).foregroundStyle(.secondary), textScale: textScale, zoom: zoom, metrics: metrics, width: metrics.halfTextWidth) {
                    ai.requestSuggestions(for: node.id, in: document, undoManager: undoManager, limit: 3)
                }
                .disabled(suggesting || full)
                .opacity(suggesting || full ? 0.5 : 1)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: metrics.rowWidth, alignment: .leading)
        .clipped()
    }

    /// `width`가 없으면 글자 길이에 맞춰 최대 폭까지 늘어나고, 있으면 그 폭으로 고정한다.
    private func chip(_ label: Text, textScale: Double, zoom: CGFloat, metrics: ChipMetrics, width: CGFloat? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .font(.scaled(.callout, textScale))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: width)
                .frame(maxWidth: width == nil ? metrics.textMaxWidth : nil)
                .padding(.horizontal, Self.chipPadding)
                .padding(.vertical, 9)
                .layeredFill(Capsule(), tint: Color.accentColor.opacity(0.14))
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.6), lineWidth: 1 / zoom))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
    }

    // 직접 질문 입력

    private func startCompose(_ id: WID) {
        composeText = ""
        withAnimation(Self.focusSpring) { composingFor = id }
        // 입력란이 생긴 뒤에 포커스를 준다.
        DispatchQueue.main.async { composeFocused = true }
    }

    private func cancelCompose() {
        composeFocused = false
        composeText = ""
        withAnimation(Self.focusSpring) { composingFor = nil }
    }

    private func submitCompose(parent: WID) {
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        cancelCompose()
        createCustomChild(of: parent, question: text)
    }

    private func createCustomChild(of parent: WID, question: String) {
        var created: WID?
        withAnimation(Self.focusSpring) {
            document.perform("Ask Your Own", undoManager: undoManager) {
                created = $0.addCustomChild(of: parent, question: question)
            }
        }
        if let created {
            start(created, focus: false)
            arrange(around: created)
        }
    }

    /// 호버한 노드 자신과, 트리 선 · 참조선으로 바로 이어진 노드
    private func isHighlighted(_ id: WID) -> Bool {
        guard let hoveredId = canvas.hoveredId, let hovered = map[hoveredId], let node = map[id] else { return false }
        return id == hoveredId || node.parentId == hoveredId || hovered.parentId == id
            || node.refs.contains { $0.nodeId == hoveredId } || hovered.refs.contains { $0.nodeId == id }
    }

    /// 빛은 갑자기 켜지지 않고 0.5초 안에 은은하게 밝아지고 옅어진다.
    /// 애니메이션은 빛 쪽에서 직접 건다(NodeBubble · EdgeLayer).
    private func hover(_ id: WID, _ inside: Bool) {
        if inside {
            canvas.hoveredId = id
        } else if canvas.hoveredId == id {
            canvas.hoveredId = nil
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
        closeStylePanel()
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
            document.perform("Choose Suggestion", undoManager: undoManager) {
                created = $0.addChild(of: parentId, suggestion: suggestion.id)
            }
        }
        // 포커스를 부모에 그대로 두어 남은 추가 질문을 이어서 고를 수 있게 한다.
        if let created {
            start(created, focus: false)
            arrange(around: created)
        }
    }

    private func start(_ id: WID, focus: Bool = true) {
        if focus { focusedId = id }
        ai.requestAnswer(for: id, in: document, undoManager: undoManager)
    }

    private func retry(_ id: WID) {
        document.perform("Regenerate Answer", undoManager: undoManager) { $0.beginRegenerate(id) }
        ai.requestAnswer(for: id, in: document, undoManager: undoManager)
    }

    // 노드 편집 패널 (우클릭)

    struct StyleTarget: Equatable {
        let id: WID
        let point: CGPoint
    }

    /// 마우스가 올라가 있는 노드를 우클릭하면 그 자리 옆에 패널을 연다. 노드가 아니면 이벤트를 넘긴다.
    private func openStylePanel(at point: CGPoint) -> Bool {
        guard !canvas.isRunning, let id = canvas.hoveredId, map[id] != nil else {
            closeStylePanel()
            return false
        }
        styleUndoRegistered = false
        styleTarget = StyleTarget(id: id, point: point)
        return true
    }

    private func closeStylePanel() {
        guard styleTarget != nil else { return }
        styleTarget = nil
        styleUndoRegistered = false
    }

    @ViewBuilder
    private var stylePanel: some View {
        if let target = styleTarget, let node = map[target.id] {
            NodeStylePanel(
                node: node,
                canToggleBranch: node.id != map.rootId && !map.childIDs(of: node.id).isEmpty,
                canDelete: node.id != map.rootId && !isAwaitingAI(inBranchOf: node.id),
                onTextScale: { value in editStyle { $0.setTextScale(node.id, value) } },
                onSizeScale: { value in editStyle { $0.setSizeScale(node.id, value) } },
                onFill: { value in editStyle { $0.setColors(node.id, fill: .some(value)) } },
                onText: { value in editStyle { $0.setColors(node.id, text: .some(value)) } },
                onToggleBranch: {
                    closeStylePanel()
                    document.perform(node.collapsed ? "Expand Branch" : "Collapse Branch", undoManager: undoManager) {
                        $0.setCollapsed(node.id, !node.collapsed)
                    }
                },
                onReset: { editStyle { $0.resetStyle(node.id) } },
                onDelete: {
                    closeStylePanel()
                    document.perform("Delete Node", undoManager: undoManager) { $0.deleteSubtree(node.id) }
                    if let focusedId, map[focusedId] == nil { self.focusedId = nil }
                }
            )
            .onGeometryChange(for: CGSize.self) { $0.size } action: { stylePanelSize = $0 }
            .position(stylePanelPosition(near: target.point))
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    /// 누른 자리 오른쪽 아래에 두되, 창 밖으로 나가면 왼쪽 · 위로 옮긴다.
    private func stylePanelPosition(near point: CGPoint) -> CGPoint {
        let size = stylePanelSize
        let margin: CGFloat = 8
        var x = point.x + 16 + size.width / 2
        if x + size.width / 2 > canvas.viewSize.width - margin { x = point.x - 16 - size.width / 2 }
        x = min(max(x, size.width / 2 + margin), canvas.viewSize.width - size.width / 2 - margin)
        let y = min(max(point.y + size.height / 2 - 20, size.height / 2 + margin), canvas.viewSize.height - size.height / 2 - margin)
        return CGPoint(x: x, y: y)
    }

    /// 패널이 열린 동안 첫 편집만 실행 취소 단계로 등록하고, 이어지는 편집은 그 단계에 합친다.
    private func editStyle(_ change: (inout MindMap) -> Void) {
        if styleUndoRegistered {
            document.applyWithoutUndo(change)
            markDocumentEdited()
        } else {
            let before = map
            document.perform("Edit Node Style", undoManager: undoManager, change)
            if map != before { styleUndoRegistered = true }
        }
    }

    /// 이 노드나 그 아래 가지에 AI 답변 · 추가 질문을 기다리는 노드가 있는지. 있으면 삭제를 막는다(SPEC 6.6).
    /// 도중에 끊긴 요청은 사용량을 알 수 없어 토큰이 새기 때문이다.
    private func isAwaitingAI(inBranchOf id: WID) -> Bool {
        let waiting = Set(settings.requests.requests(in: ObjectIdentifier(document)).map(\.key.node))
        guard !waiting.isEmpty else { return false }
        return map.subtreeIDs(of: id).contains { waiting.contains($0) }
    }

    /// ⌫ · ⌦: 포커스 노드와 그 아래 가지를 확인 없이 지운다. ⌘Z로 되돌린다. 루트는 지우지 않는다.
    private func deleteFocused() -> Bool {
        guard let id = focusedId, id != map.rootId, map[id] != nil, !isAwaitingAI(inBranchOf: id) else { return false }
        document.perform("Delete Node", undoManager: undoManager) { $0.deleteSubtree(id) }
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
            let previous = map.root.question
            document.perform("Enter Topic", undoManager: undoManager) { $0.setRootQuestion(text) }
            renameProject(from: previous)
            if map.root.status == .pending { start(map.rootId) }
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
            .onChanged { value in
                closeStylePanel()
                canvas.livePan = value.translation
            }
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
            .onChanged { value in
                closeStylePanel()
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
                // 자동 정리 중에 노드를 잡으면 정리를 먼저 끝내고 평소처럼 옮긴다(놓으면 고정 · 실행 취소 1회).
                if canvas.isSimulating, !canvas.isRunning { finishPhysics() }
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
                    document.perform("Move Node", undoManager: undoManager) { $0.move(node.id, to: (x, y)) }
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

    /// 포커스를 먼저 풀어 모든 노드를 원으로 접은 뒤 시작한다. 자동 정리가 돌던 중이면 그 결과를 먼저 반영한다.
    private func startPhysics() {
        guard map.nodes.count > 1 else { return }
        if canvas.isSimulating { finishPhysics() }
        focusedId = nil
        canvas.textPinch = nil
        closeStylePanel()
        canvas.startSimulation(ForceSimulation(map: map, settings: settings.physics), manual: true)
        ticker.start { stepPhysics() }
    }

    /// 새 노드가 기존 노드와 겹치지 않도록 그 주변만 안정될 때까지 시뮬레이션한다 (SPEC 8.4 부분 계산).
    /// 새 노드 · 형제 · 형제의 자식만 움직이고, 부모 · 루트 · 사용자가 옮긴 노드와 나머지는 고정된 장애물이다.
    private func arrange(around id: WID) {
        // 버튼 시뮬레이션 중이면 새 노드도 그 계산에 그대로 합류한다.
        guard !canvas.isRunning else { return }
        var area = arrangeArea(around: id)
        if let current = canvas.simulation?.movable {
            // 자동 정리 중에 또 만들면 범위를 넓혀 이어서 돌린다. 새 노드는 다음 동기화 때 합류한다.
            area.formUnion(current)
            canvas.simulation?.setMovable(area)
            canvas.simulation?.reheat(to: 0.6)
            return
        }
        canvas.startSimulation(ForceSimulation(map: map, settings: settings.physics, movable: area, alpha: 0.6), manual: false)
        ticker.start { stepPhysics() }
    }

    private func arrangeArea(around id: WID) -> Set<WID> {
        guard let pid = map[id]?.parentId else { return [id] }
        var area: Set<WID> = [id]
        for sibling in map.childIDs(of: pid) {
            area.insert(sibling)
            area.formUnion(map.childIDs(of: sibling))
        }
        area.remove(pid)
        area.remove(map.rootId)
        return area.filter { $0 == id || map[$0]?.position.pinned != true }
    }

    private func stepPhysics() {
        guard canvas.simulation != nil else { return ticker.stop() }
        var still = false
        withoutAnimation { still = canvas.simulation?.tick() ?? false }
        // 잡고 있는 동안에는 멈추지 않는다.
        if !still, canvas.holdOrigin == nil { finishPhysics() }
    }

    /// 버튼 시뮬레이션은 멈춘 자리를 실행 취소 1회로, 자동 정리는 실행 취소 없이 문서에 반영한다.
    private func finishPhysics() {
        ticker.stop()
        guard canvas.simulation != nil else { return }
        let manual = canvas.isRunning
        withoutAnimation {
            guard let positions = canvas.stopSimulation() else { return }
            if manual {
                document.perform("Simulation", undoManager: undoManager) { $0.arrange(positions) }
            } else {
                // 자동 배치는 사용자가 고정한 노드를 건드리지 않는다.
                document.applyWithoutUndo { $0.applyLayout(positions) }
                markDocumentEdited()
            }
        }
    }

    /// 프로젝트 파일 이름을 루트 주제(첫 노드의 질문)로 맞춘다. 사용자가 직접 바꾼 이름은 그대로 둔다.
    private func renameProject(from previousTopic: String) {
        #if os(macOS)
        ProjectFiles.renameToTopic(canvas.window?.windowController?.document as? NSDocument, previousTopic: previousTopic, topic: map.root.question)
        #endif
    }

    /// 자동 정리를 결과 반영 없이 멈춘다.
    private func cancelAutoArrange() {
        ticker.stop()
        withoutAnimation { _ = canvas.stopSimulation() }
    }

    /// 실행 취소에 쌓지 않은 변경도 저장되도록, 이 화면이 놓인 문서 창의 문서에 변경 표시만 한다 (SPEC 7.6).
    private func markDocumentEdited() {
        #if os(macOS)
        (canvas.window?.windowController?.document as? NSDocument)?.updateChangeCount(.changeDone)
        #endif
    }

    /// 조절값을 바꾸면 결과가 바로 보이도록, 도는 중이면 다시 데우고 멈춰 있으면 시작한다.
    private func physicsChanged() {
        if !canvas.isRunning {
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
        #if os(macOS)
        ToolbarItem(placement: .navigation) {
            Button { backToProjects() } label: { Label("Projects", systemImage: "square.grid.2x2") }
                .help("Back to Projects")
        }
        #endif
        ToolbarItemGroup {
            // 설정은 메뉴 막대 WhyNode > 설정(⌘,)으로 연다.
            Button { animateCamera(scale: canvas.scale / 1.25) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                .help("Zoom out the canvas")
            Button { animateCamera(scale: canvas.scale * 1.25) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                .help("Zoom in the canvas")
            Button { animateCamera(scale: 1, offset: .zero) } label: { Label("Center", systemImage: "scope") }
                .help("Back to the center at actual size")
            Button { settings.stepTextScale(-1) } label: { Label("Smaller Text", systemImage: "textformat.size.smaller") }
                .disabled(settings.textScale <= SettingsStore.textScaleRange.lowerBound)
                .help("Smaller text for all nodes (⌘-)")
            Button { settings.stepTextScale(1) } label: { Label("Larger Text", systemImage: "textformat.size.larger") }
                .disabled(settings.textScale >= SettingsStore.textScaleRange.upperBound)
                .help("Larger text for all nodes (⌘=)")
        }
    }

    #if os(macOS)
    /// 프로젝트 선택 화면으로 돌아간다. 문서는 자동 저장되어 있으므로 이 창을 닫는다.
    private func backToProjects() {
        finishPhysics()
        openWindow(id: LauncherView.windowId)
        canvas.window?.performClose(nil)
    }
    #endif

    private func updateProvider() {
        do {
            ai.provider = try settings.makeProvider()
        } catch {
            ai.provider = nil
            ai.notice = error.localizedDescription
        }
    }
}

/// 알림창 입력. 지금은 새 프로젝트의 주제 입력에만 쓴다.
enum PromptRequest: Equatable {
    case root

    var title: LocalizedStringKey { "What are you curious about?" }
    var placeholder: LocalizedStringKey { "A topic or question (e.g. quantum mechanics)" }
}
