import SwiftUI
import WhyNodeCore

/// 원형 노드. 컴팩트일 때는 질문만, 펼치면 답변 본문까지 보인다 (SPEC 2.4).
struct NodeBubble: View {
    static let compactDiameter: CGFloat = 140
    static let expandedDiameter: CGFloat = 360

    let node: Node
    let isExpanded: Bool
    let isFocused: Bool
    let isDimmed: Bool
    let isSuggesting: Bool
    let onRetry: () -> Void
    let onCustomQuestion: () -> Void

    private var showsDetail: Bool { isExpanded && node.status != .empty }
    private var diameter: CGFloat { showsDetail ? Self.expandedDiameter : Self.compactDiameter }

    var body: some View {
        VStack(spacing: 10) {
            Text(node.question.isEmpty ? "주제를 입력하세요" : node.question)
                .font(showsDetail ? .headline : .callout.weight(.medium))
                .foregroundStyle(node.question.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .lineLimit(showsDetail ? 3 : 4)

            if showsDetail {
                detail
            }

            if node.status == .pending || isSuggesting {
                ProgressView().controlSize(.small)
            }
            if node.collapsed {
                Label("접힘", systemImage: "chevron.right.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // 원의 곡률을 고려해 위아래 여백을 좌우보다 조금 더 둔다.
        .padding(.horizontal, showsDetail ? 44 : 18)
        .padding(.vertical, showsDetail ? 50 : 20)
        .frame(width: diameter, height: diameter)
        .layeredFill(Circle(), tint: Theme.tint(for: node.status))
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.border(for: node.status, focused: isFocused), lineWidth: isFocused ? 2.5 : 1))
        .shadow(color: .black.opacity(0.18), radius: isFocused ? 10 : 5, y: 2)
        .opacity(isDimmed ? 0.3 : 1)
    }

    @ViewBuilder
    private var detail: some View {
        if let answer = node.answer {
            // 원 안에 다 들어가면 그대로 보여주고, 넘칠 때만 스크롤한다.
            ViewThatFits(in: .vertical) {
                answerBody(answer)
                ScrollView { answerBody(answer) }
            }
            .frame(maxHeight: 180)
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
        if node.status == .done {
            Button("직접 질문", systemImage: "plus.bubble", action: onCustomQuestion)
                .controlSize(.small)
        }
    }

    private func answerBody(_ answer: String) -> some View {
        AnswerView(markdown: answer)
    }
}
