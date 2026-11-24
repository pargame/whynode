import SwiftUI
import WhyNodeCore

/// 노드. 평소에는 질문만 담은 원이고, 포커스되면 질문은 제자리에 둔 채 아래로 넓어지는 둥근 네모가 되며 본문이 나타난다 (SPEC 2.4).
/// 뷰의 위쪽 가운데가 기준점이며, 질문의 중심은 항상 위에서 `titleCenter`만큼 떨어진 곳에 있다.
struct NodeBubble: View, Equatable {
    static let compactDiameter: CGFloat = 140
    static let expandedWidth: CGFloat = 380
    static var titleCenter: CGFloat { compactDiameter / 2 }
    /// 질문은 펼쳐도 줄바꿈이 바뀌지 않도록 원 안의 폭 그대로 둔다.
    static let titleWidth: CGFloat = 108

    let node: Node
    let isFocused: Bool
    let isDimmed: Bool
    let isSuggesting: Bool
    /// 시뮬레이션 · 끌기 중에는 그림자를 끈다. 뷰를 갈아 끼우지 않도록 값만 바꾼다.
    var isQuiet = false
    /// 화면 배율. 노드는 배율만큼 커지고 작아지지만 테두리는 화면에서 같은 굵기로 보이도록 나눠 준다.
    var zoom: CGFloat = 1
    /// 호버한 노드이거나 그 이웃이면 테두리 안쪽으로 빛이 번진다. 참조선으로만 이어진 이웃은 점선 빛이다.
    var glow: NodeGlow = .none
    let onRetry: () -> Void

    /// 위치가 바뀌는 매 프레임마다 다시 계산하지 않도록, 그리는 데 쓰는 값만 비교한다.
    static func == (lhs: NodeBubble, rhs: NodeBubble) -> Bool {
        lhs.node == rhs.node && lhs.isFocused == rhs.isFocused && lhs.isDimmed == rhs.isDimmed
            && lhs.isSuggesting == rhs.isSuggesting && lhs.isQuiet == rhs.isQuiet
            && lhs.zoom == rhs.zoom && lhs.glow == rhs.glow
    }

    private var showsDetail: Bool { isFocused && node.status != .empty }
    private var shape: RoundedRectangle { NodeBubble.shape(expanded: showsDetail, size: node.sizeScale) }

    /// `size`는 노드 크기 배율. 원은 지름이 함께 커져 계속 원으로 보인다.
    static func shape(expanded: Bool, size: Double) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: expanded ? 22 * size : compactDiameter * size / 2, style: .continuous)
    }

    /// 본문은 화면 배율을 모르는 하위 뷰로 두어, 확대 · 축소 중에는 테두리 · 빛만 다시 그린다.
    var body: some View {
        NodeBubbleBody(node: node, isFocused: isFocused, isSuggesting: isSuggesting, onRetry: onRetry)
            .equatable()
            .overlay(shape.stroke(Theme.border(for: node.status, focused: isFocused), lineWidth: (isFocused ? 2.5 : 1) / zoom))
            // 노드 자체는 불투명하게 두고 배경색 막을 덮어 흐리게 한다. 투명도를 낮추면 뒤의 선이 노드 위로 비친다.
            .overlay(shape.fill(Theme.canvas.opacity(isDimmed ? 0.7 : 0)).allowsHitTesting(false))
            .overlay {
                // 프레넬 효과처럼 가장자리가 가장 밝고 안쪽으로 갈수록 옅어지는 빛. 테두리 굵기처럼 화면 배율과 상관없이 같게 보인다.
                // 점선 빛은 참조선과 같은 박자(6 · 5)로 끊어, 어느 선으로 이어진 이웃인지 모양으로 구분한다.
                ZStack {
                    if glow != .none {
                        let dash: [CGFloat] = glow == .dashed ? [6 / zoom, 5 / zoom] : []
                        ZStack {
                            shape.stroke(Theme.glow.opacity(0.7), style: StrokeStyle(lineWidth: 10 / zoom, dash: dash))
                                .blur(radius: 6 / zoom)
                                .clipShape(shape)
                            shape.stroke(Theme.glow.opacity(0.9), style: StrokeStyle(lineWidth: 1.5 / zoom, lineCap: .round, dash: dash))
                        }
                        .transition(.opacity)
                    }
                }
                .allowsHitTesting(false)
                // 빛만 은은하게 켜고 끈다. 같은 순간의 화면 이동 등에는 애니메이션이 섞이지 않는다.
                .animation(Theme.glowAnimation, value: glow)
            }
            .shadow(color: isQuiet ? .clear : .black.opacity(isDimmed ? 0.05 : 0.18), radius: isQuiet ? 0 : isFocused ? 10 : 5, y: isQuiet ? 0 : 2)
            .contentShape(shape)
    }
}

/// 호버 빛. 호버한 노드 자신과 트리 선 이웃은 실선, 참조선으로만 이어진 이웃은 점선이다.
enum NodeGlow: Equatable {
    case none, solid, dashed
}

/// 노드 본문(질문 · 답변 · 상태). 화면 배율 · 흐림 · 빛과 무관한 값만 받아, 그 값이 같으면 다시 계산하지 않는다.
private struct NodeBubbleBody: View, Equatable {
    let node: Node
    let isFocused: Bool
    let isSuggesting: Bool
    let onRetry: () -> Void

    static func == (lhs: NodeBubbleBody, rhs: NodeBubbleBody) -> Bool {
        lhs.node == rhs.node && lhs.isFocused == rhs.isFocused && lhs.isSuggesting == rhs.isSuggesting
    }

    /// 원 안 질문은 이 높이(기준 글자 4줄) 안에 들어가는 가장 큰 크기로 그린다. 펼쳐도 같은 크기를 쓴다.
    private var fitHeight: CGFloat { Self.lineHeight(scale: 1) * 4 * size }
    /// 큰 것부터 차례로 맞춰 본다. 가장 작은 크기로도 넘치면 원에서는 그 크기로 줄 수를 자르고 생략(…)한다.
    private static let fitScales: [CGFloat] = [1.8, 1.6, 1.4, 1.25, 1.1, 1.0, 0.9, 0.8]

    #if os(macOS)
    private typealias PlatformFont = NSFont
    #else
    private typealias PlatformFont = UIFont
    #endif

    private static func platformFont(scale: CGFloat) -> PlatformFont {
        PlatformFont.systemFont(ofSize: Font.baseSize(.callout) * scale, weight: .medium)
    }

    private static func lineHeight(scale: CGFloat) -> CGFloat {
        let font = platformFont(scale: scale)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// 가장 긴 단어의 폭. 단어가 한 줄에 다 들어가지 않는 크기는 단어 중간이 끊기므로 고르지 않는다.
    private static func longestWordWidth(_ text: String, scale: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: platformFont(scale: scale)]
        return text.split(whereSeparator: \.isWhitespace)
            .map { ceil((String($0) as NSString).size(withAttributes: attributes).width) }
            .max() ?? 0
    }

    private var displayText: String { node.question.isEmpty ? String(localized: "Enter a topic") : node.question }

    /// 질문을 이 폭으로 줄바꿈했을 때의 높이
    private static func textHeight(_ text: String, scale: CGFloat, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: platformFont(scale: scale), .paragraphStyle: paragraph]
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        return ceil(rect.height)
    }

    /// 글자 크기 배율: 단어가 끊기지 않고 원 안(`fitHeight`)에 다 들어가는 가장 큰 크기. 없으면 가장 작은 크기.
    private var fittedScale: CGFloat {
        let width = NodeBubble.titleWidth * size
        let text = displayText
        let safe = Self.fitScales.filter { Self.longestWordWidth(text, scale: $0) <= width }
        return safe.first { Self.textHeight(text, scale: $0, width: width) <= fitHeight } ?? Self.fitScales.last!
    }

    /// 원 안에 들어가는 줄 수. 넘치는 질문은 여기서 잘라 생략(…)한다.
    private func compactLineLimit(scale: CGFloat) -> Int {
        max(1, Int((fitHeight / Self.lineHeight(scale: scale)).rounded(.down)))
    }

    /// 원 안 질문의 높이. 질문의 중심이 원의 중심에 오도록 위 여백을 정하고, 펼쳐도 같은 여백이라 첫 줄이 움직이지 않는다.
    @State private var compactTitleHeight: CGFloat = 20

    private var showsDetail: Bool { isFocused && node.status != .empty }
    private var size: CGFloat { node.sizeScale }
    private var shape: RoundedRectangle { NodeBubble.shape(expanded: showsDetail, size: size) }
    /// 사용자가 고른 글자 색. 없으면 기본(주 · 보조 색)
    private var textColor: Color? { Theme.nodeColor(node.textColor) }

    var body: some View {
        VStack(spacing: 12) {
            // 질문 길이에 맞춰 정한 크기를 원과 펼친 카드에 똑같이 쓴다. 원에서는 정해진 줄 수까지만, 펼치면 전체를 보여준다.
            let scale = fittedScale
            let lines = compactLineLimit(scale: scale)
            title(scale: scale, lineLimit: showsDetail ? nil : lines)
                .foregroundStyle(node.question.isEmpty ? AnyShapeStyle(.secondary) : textColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .background {
                    title(scale: scale, lineLimit: lines)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { compactTitleHeight = $0 }
                }

            if showsDetail {
                detail
                    .padding(.horizontal, 20)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if node.status == .pending || isSuggesting {
                ProgressView().controlSize(.small)
            }
            if node.collapsed {
                Label("Collapsed", systemImage: "chevron.right.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // 질문의 중심이 원의 중심(위에서 70pt)에 오도록 위 여백을 맞춘다. 펼쳐도 같은 여백이라 질문이 움직이지 않는다.
        .padding(.top, max(10, NodeBubble.titleCenter * size - compactTitleHeight / 2))
        .padding(.bottom, showsDetail ? 18 : 0)
        .frame(width: (showsDetail ? NodeBubble.expandedWidth : NodeBubble.compactDiameter) * size, alignment: .top)
        .frame(minHeight: NodeBubble.compactDiameter * size, alignment: .top)
        .frame(height: showsDetail ? nil : NodeBubble.compactDiameter * size, alignment: .top)
        // 사용자가 고른 노드 색이 상태 색(대기 노랑 · 오류 빨강)보다 우선하고, 상태는 테두리로 남는다.
        .layeredFill(shape, tint: Theme.nodeColor(node.fillColor).map { $0.opacity(0.28) } ?? Theme.tint(for: node.status))
        .clipShape(shape)
    }

    private func title(scale: CGFloat, lineLimit: Int?) -> some View {
        (node.question.isEmpty ? Text("Enter a topic") : Text(verbatim: node.question))
            .font(.scaled(.callout, scale, weight: .medium))
            .multilineTextAlignment(.center)
            .lineLimit(lineLimit)
            .frame(width: NodeBubble.titleWidth * size)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 12) {
            if let answer = node.answer {
                // 스크롤 영역은 크기를 스스로 정하지 못해 높이가 0으로 접히므로 쓰지 않는다.
                // 분량은 답변 서식 제한(SPEC 6.5)으로 묶여 있어 카드가 무한히 길어지지 않는다.
                AnswerView(markdown: answer, color: textColor)
            }
            if node.status == .done {
                // 답변이 마음에 들지 않으면 다시 받는다. 받는 동안 이전 답변은 그대로 보이고, 실패해도 남는다.
                HStack {
                    Spacer()
                    Button(action: onRetry) {
                        Label("Regenerate Answer", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            if node.status == .pending || isSuggesting {
                ProgressView().controlSize(.small)
            }
            if node.status == .error {
                (node.error.map { Text(verbatim: $0) } ?? Text("Error"))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("Retry", action: onRetry)
                    .controlSize(.small)
            }
        }
    }
}
