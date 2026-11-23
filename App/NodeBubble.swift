import SwiftUI
import WhyNodeCore

/// 노드. 평소에는 질문만 담은 원이고, 포커스되면 질문은 제자리에 둔 채 아래로 넓어지는 둥근 네모가 되며 본문이 나타난다 (SPEC 2.4).
/// 뷰의 위쪽 가운데가 기준점이며, 질문의 중심은 항상 위에서 `titleCenter`만큼 떨어진 곳에 있다.
struct NodeBubble: View {
    static let compactDiameter: CGFloat = 140
    static let expandedWidth: CGFloat = 380
    static var titleCenter: CGFloat { compactDiameter / 2 }
    /// 질문은 펼쳐도 줄바꿈이 바뀌지 않도록 원 안의 폭 그대로 둔다.
    static let titleWidth: CGFloat = 108

    let node: Node
    let isFocused: Bool
    let isDimmed: Bool
    let isSuggesting: Bool
    let onRetry: () -> Void

    @State private var titleHeight: CGFloat = 20

    private var showsDetail: Bool { isFocused && node.status != .empty }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: showsDetail ? 22 : Self.compactDiameter / 2, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(node.question.isEmpty ? "주제를 입력하세요" : node.question)
                .font(.callout.weight(.medium))
                .foregroundStyle(node.question.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(width: Self.titleWidth)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleHeight = $0 }

            if showsDetail {
                detail
                    .padding(.horizontal, 20)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if node.status == .pending || isSuggesting {
                ProgressView().controlSize(.small)
            }
            if node.collapsed {
                Label("접힘", systemImage: "chevron.right.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // 질문의 중심이 원의 중심(위에서 70pt)에 오도록 위 여백을 맞춘다. 펼쳐도 같은 여백이라 질문이 움직이지 않는다.
        .padding(.top, max(10, Self.titleCenter - titleHeight / 2))
        .padding(.bottom, showsDetail ? 18 : 0)
        .frame(width: showsDetail ? Self.expandedWidth : Self.compactDiameter, alignment: .top)
        .frame(minHeight: Self.compactDiameter, alignment: .top)
        .frame(height: showsDetail ? nil : Self.compactDiameter, alignment: .top)
        .layeredFill(shape, tint: Theme.tint(for: node.status))
        .clipShape(shape)
        .overlay(shape.stroke(Theme.border(for: node.status, focused: isFocused), lineWidth: isFocused ? 2.5 : 1))
        // 노드 자체는 불투명하게 두고 배경색 막을 덮어 흐리게 한다. 투명도를 낮추면 뒤의 선이 노드 위로 비친다.
        .overlay(shape.fill(Theme.canvas.opacity(isDimmed ? 0.7 : 0)).allowsHitTesting(false))
        .shadow(color: .black.opacity(isDimmed ? 0.05 : 0.18), radius: isFocused ? 10 : 5, y: 2)
        .contentShape(shape)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 12) {
            if let answer = node.answer {
                // 스크롤 영역은 크기를 스스로 정하지 못해 높이가 0으로 접히므로 쓰지 않는다.
                // 분량은 답변 서식 제한(SPEC 6.5)으로 묶여 있어 카드가 무한히 길어지지 않는다.
                AnswerView(markdown: answer)
            }
            if node.status == .pending || isSuggesting {
                ProgressView().controlSize(.small)
            }
            if node.status == .error {
                Text(node.error ?? "오류")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("다시 시도", action: onRetry)
                    .controlSize(.small)
            }
        }
    }
}
