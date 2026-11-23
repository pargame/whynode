import SwiftUI
import WhyNodeCore

/// 원형 노드. 컴팩트일 때는 질문만, 펼치면 답변 본문까지 보인다 (SPEC 2.4).
struct NodeBubble: View {
    let node: Node
    let isExpanded: Bool
    let isFocused: Bool
    let isDimmed: Bool
    let isSuggesting: Bool
    let onRetry: () -> Void
    let onCustomQuestion: () -> Void

    private var diameter: CGFloat { isExpanded && node.status != .empty ? 300 : 140 }

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .overlay(Circle().stroke(stroke, lineWidth: isFocused ? 3 : 1.5))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)

            VStack(spacing: 8) {
                Text(node.question.isEmpty ? "주제를 입력하세요" : node.question)
                    .font(isExpanded ? .headline : .callout)
                    .foregroundStyle(node.question.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(isExpanded ? 3 : 4)

                if isExpanded {
                    expandedContent
                }

                if node.status == .pending || isSuggesting {
                    ProgressView().controlSize(.small)
                }
                if node.collapsed {
                    Label("접힘", systemImage: "chevron.right.circle").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(diameter * 0.16)
        }
        .frame(width: diameter, height: diameter)
        .opacity(isDimmed ? 0.3 : 1)
    }

    @ViewBuilder
    private var expandedContent: some View {
        if let answer = node.answer {
            ScrollView {
                Text(LocalizedStringKey(answer))
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        }
        if node.status == .error {
            Text(node.error ?? "오류")
                .font(.caption)
                .foregroundStyle(.red)
            Button("다시 시도", action: onRetry)
                .controlSize(.small)
        }
        if node.status == .done {
            Button("직접 질문", systemImage: "plus.bubble", action: onCustomQuestion)
                .controlSize(.small)
                .buttonStyle(.borderless)
        }
    }

    private var fill: Color {
        switch node.status {
        case .empty: Color(white: 0.93)
        case .pending: Color.yellow.opacity(0.12)
        case .done: Color.white
        case .error: Color.red.opacity(0.08)
        }
    }

    private var stroke: Color {
        isFocused ? .blue : node.status == .error ? .red.opacity(0.6) : .gray.opacity(0.5)
    }
}
