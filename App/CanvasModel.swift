import SwiftUI
import WhyNodeCore

/// 캔버스의 카메라 · 노드 끌기 · 시뮬레이션 상태. 매 프레임 바뀌는 값을 여기에 모아,
/// 그 값을 읽는 노드 층 · 선 층만 다시 그리고 `MapScreen` 전체는 다시 계산하지 않게 한다.
@Observable
final class CanvasModel {
    /// 확정된 화면 배율 · 이동량. 제스처 중의 값은 아래 live 값에 따로 둔다.
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    var livePan: CGSize = .zero
    var liveZoom: CGFloat = 1
    var zoomAnchor: CGPoint?
    var viewSize: CGSize = .zero
    /// 끌고 있는 노드와 화면상 이동량. 손을 떼기 전까지 노드와 선이 손가락을 따라온다.
    var dragging: (id: WID, translation: CGSize)?
    /// 시뮬레이션이 도는 동안의 시뮬레이션. 멈추면 결과를 문서에 한 번 반영하고 nil이 된다 (SPEC 2.6).
    var simulation: ForceSimulation?
    /// 마우스를 올린 노드. 이 노드와 이웃의 테두리 · 선을 은은하게 밝힌다.
    var hoveredId: WID?
    /// 펼친 노드 안에서 핀치 중인 노드와 배율. 손을 떼면 노드의 글자 크기로 확정된다.
    var textPinch: (id: WID, factor: CGFloat)?
    /// 시뮬레이션 중에 잡은 노드의 시작 위치(월드 좌표)
    var holdOrigin: CGPoint?
    /// 버튼으로 켠 시뮬레이션이 도는 중인지. `simulation`과 따로 둔다. 계산 프로퍼티로 두면 이 값을 읽는 화면이 매 틱 다시 계산된다.
    private(set) var isRunning = false
    /// 버튼 시뮬레이션이든 새 노드 주변 자동 정리든 시뮬레이션이 도는 중인지
    private(set) var isSimulating = false

    static let minScale: CGFloat = 0.2
    static let maxScale: CGFloat = 3

    static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, minScale), maxScale)
    }

    var center: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }
    var effectiveScale: CGFloat { Self.clamp(scale * liveZoom) }

    /// 핀치 중에는 손가락 아래의 지점이 그대로 있도록 이동량을 보정한다.
    var effectiveOffset: CGSize {
        guard let anchor = zoomAnchor else {
            return CGSize(width: offset.width + livePan.width, height: offset.height + livePan.height)
        }
        let ratio = effectiveScale / scale
        return CGSize(
            width: anchor.x - center.x - (anchor.x - center.x - offset.width) * ratio,
            height: anchor.y - center.y - (anchor.y - center.y - offset.height) * ratio
        )
    }

    /// 움직이는 동안에는 그림자를 꺼 프레임마다 드는 그리기 비용을 줄인다.
    var isMoving: Bool { isRunning || dragging != nil }

    /// 시뮬레이션 중에는 시뮬레이션 위치를, 끌고 있는 노드는 손가락 이동량만큼 더해 그린다.
    /// 핀치 중인 값까지 반영한 노드 글자 크기 배율
    func textScale(of node: Node) -> Double {
        guard let textPinch, textPinch.id == node.id else { return node.textScale }
        return Node.clampedTextScale(node.textScale * textPinch.factor)
    }

    func worldPoint(of node: Node) -> CGPoint {
        if let p = simulation?.position(of: node.id) { return CGPoint(x: p.x, y: p.y) }
        var point = CGPoint(x: node.position.x, y: node.position.y)
        if let dragging, dragging.id == node.id {
            point.x += dragging.translation.width / effectiveScale
            point.y += dragging.translation.height / effectiveScale
        }
        return point
    }

    func screenPoint(of node: Node) -> CGPoint {
        let world = worldPoint(of: node)
        let offset = effectiveOffset
        let scale = effectiveScale
        return CGPoint(x: center.x + offset.width + world.x * scale, y: center.y + offset.height + world.y * scale)
    }

    /// `manual`은 버튼으로 켠 시뮬레이션, 아니면 새 노드 주변 자동 정리다.
    func startSimulation(_ simulation: ForceSimulation, manual: Bool) {
        self.simulation = simulation
        isRunning = manual
        isSimulating = true
    }

    /// 멈춘 시뮬레이션의 위치를 돌려주고 상태를 비운다.
    func stopSimulation() -> [WID: (x: Double, y: Double)]? {
        let positions = simulation?.positions
        simulation = nil
        holdOrigin = nil
        isRunning = false
        isSimulating = false
        return positions
    }
}

/// 노드 층. 노드 위치를 여기서만 읽어, 시뮬레이션 · 화면 이동 중에는 이 층만 다시 그린다.
struct NodeLayer<Content: View>: View {
    let nodes: [Node]
    let canvas: CanvasModel
    let focusedId: WID?
    @ViewBuilder let content: (Node) -> Content

    var body: some View {
        let scale = canvas.effectiveScale
        ForEach(nodes) { node in
            // 크기가 없는 기준점을 노드 좌표(질문의 중심)에 두고, 노드는 그 위쪽 가운데에 매단다.
            // 펼쳐져도 위쪽 기준이 그대로라 질문이 제자리에 남는다.
            Color.clear
                .frame(width: 0, height: 0)
                .overlay(alignment: .top) {
                    content(node)
                        .fixedSize()
                        .scaleEffect(scale, anchor: .top)
                        .offset(y: -NodeBubble.titleCenter * scale)
                }
                .position(canvas.screenPoint(of: node))
                .zIndex(canvas.dragging?.id == node.id ? 3 : focusedId == node.id ? 2 : 0)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }
}

/// 선 층. 시뮬레이션 중에는 Canvas 하나로 한 번에 그리고, 평소에는 노드 애니메이션과 같은 박자로 움직이는 선을 쓴다.
struct EdgeLayer: View {
    let map: MindMap
    let canvas: CanvasModel
    let isDimmed: (WID) -> Bool

    var body: some View {
        let items = edgeItems
        if canvas.isSimulating {
            // 시뮬레이션 중에는 위치가 애니메이션 없이 바뀌므로 보간이 필요 없다.
            Canvas { context, _ in
                for item in items {
                    var path = Path()
                    path.move(to: item.from)
                    path.addLine(to: item.to)
                    context.stroke(path, with: .color(item.kind == .tree ? Theme.edge : Theme.refEdge), style: Self.style(item.kind))
                }
            }
            .allowsHitTesting(false)
        } else {
            ForEach(items) { edge in
                ZStack {
                    EdgeShape(from: edge.from, to: edge.to)
                        .stroke(edge.kind == .tree ? Theme.edge : Theme.refEdge, style: Self.style(edge.kind))
                        .opacity(edge.dimmed && !edge.highlighted ? 0.25 : 1)
                    if edge.highlighted {
                        ZStack {
                            EdgeShape(from: edge.from, to: edge.to)
                                .stroke(Theme.glow.opacity(0.6), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .blur(radius: 3)
                            EdgeShape(from: edge.from, to: edge.to)
                                .stroke(Theme.glow.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: edge.kind == .tree ? [] : [6, 5]))
                        }
                        .transition(.opacity)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    private static func style(_ kind: EdgeItem.Kind) -> StrokeStyle {
        StrokeStyle(lineWidth: Theme.edgeWidth, dash: kind == .tree ? [] : [6, 5])
    }

    private var edgeItems: [EdgeItem] {
        var items: [EdgeItem] = []
        let hovered = canvas.hoveredId
        for node in map.nodes {
            guard let pid = node.parentId, let parent = map[pid] else { continue }
            items.append(EdgeItem(
                id: "tree:\(node.id)", kind: .tree,
                from: canvas.screenPoint(of: parent), to: canvas.screenPoint(of: node),
                dimmed: isDimmed(node.id) && isDimmed(pid),
                highlighted: hovered != nil && (node.id == hovered || pid == hovered)
            ))
        }
        for node in map.nodes {
            for ref in node.refs {
                guard let target = map[ref.nodeId] else { continue }
                items.append(EdgeItem(
                    id: "ref:\(node.id):\(ref.nodeId)", kind: .ref,
                    from: canvas.screenPoint(of: node), to: canvas.screenPoint(of: target),
                    dimmed: isDimmed(node.id) && isDimmed(target.id),
                highlighted: hovered != nil && (node.id == hovered || target.id == hovered)
                ))
            }
        }
        return items
    }
}
