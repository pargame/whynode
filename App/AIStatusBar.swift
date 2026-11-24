import SwiftUI
import WhyNodeCore

/// 맵 화면 왼쪽 아래의 AI 상태 막대: 진행 중 · 대기 요청 수와 이 프로젝트의 누적 토큰. 누르면 자세한 내용이 펼쳐진다.
struct AIStatusBar: View {
    let center: AIRequestCenter
    let document: ObjectIdentifier
    let projectUsage: TokenUsage
    let connection: String?
    /// 짧은 모델 표시(모델 · effort). 연결 전이면 nil
    var model: String? = nil

    @State private var showsDetail = false

    private var running: Int { center.runningCount(in: document) }
    private var queued: Int { center.queuedCount(in: document) }

    var body: some View {
        Button { showsDetail.toggle() } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(connection == nil ? Color.gray : running > 0 ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                    .symbolEffect(.pulse, isActive: running > 0)
                // 평소(연결됨 · 쉬는 중)에는 글자 없이 점만 둔다. 요청 중이거나 연결이 안 됐을 때만 글로 알린다.
                if running > 0 {
                    Text("Answering \(running)")
                } else if connection == nil {
                    Text("AI not connected")
                }
                if queued > 0 {
                    Text("\(queued) queued").foregroundStyle(.secondary)
                }
                if let model {
                    Text(verbatim: model).foregroundStyle(.secondary).lineLimit(1)
                }
                Divider().frame(height: 12)
                Text("\(Self.tokens(projectUsage.totalTokens)) tokens")
                if projectUsage.costUSD > 0 {
                    Text(Self.cost(projectUsage.costUSD)).foregroundStyle(.secondary)
                }
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsDetail, arrowEdge: .top) { detail }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("This Project", usage: projectUsage)
            section("This Session", usage: center.sessionUsage)
            if let last = center.lastRequest {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Request").font(.caption.weight(.semibold))
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                        row("Type", last.kind == .answer ? Text("Answer") : Text("Suggestions"))
                        row("Input", Text(verbatim: Self.tokens(last.usage.inputTokens)))
                        row("Output", Text(verbatim: Self.tokens(last.usage.outputTokens)))
                        row("Context", Text("\(last.contextCharacters) characters"))
                        row("Time", Text(last.duration, format: .units(allowed: [.seconds], fractionalPart: .show(length: 1))))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Connection").font(.caption.weight(.semibold))
                Text(verbatim: connection ?? tr("AI is not connected"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Cost appears only when the provider reports it. Usage of requests cancelled midway may not be counted.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 280)
    }

    private func section(_ title: LocalizedStringKey, usage: TokenUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row("Input", Text(verbatim: Self.tokens(usage.inputTokens)))
                row("Output", Text(verbatim: Self.tokens(usage.outputTokens)))
                row("Requests", Text(verbatim: "\(usage.requests)"))
                if usage.costUSD > 0 {
                    row("Cost", Text(verbatim: Self.cost(usage.costUSD)))
                }
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: Text) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            value.monospacedDigit()
        }
        .font(.caption)
    }

    /// 모델 ID를 짧게 보여 준다. 끝이 effort(low · medium · high 등)면 "모델 · effort"로 나눈다. 비어 있으면 CLI · 프로바이더 기본 모델.
    static func modelLabel(_ settings: AISettings?) -> String? {
        guard let settings else { return nil }
        guard !settings.model.isEmpty else { return tr("Default model") }
        let parts = settings.model.split(separator: "-")
        let efforts: Set<String> = ["minimal", "low", "medium", "high", "xhigh", "max"]
        if parts.count > 1, let last = parts.last, efforts.contains(last.lowercased()) {
            return parts.dropLast().joined(separator: "-") + " · " + last
        }
        return settings.model
    }

    static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).locale(CoreLanguage.locale))
    }

    static func cost(_ dollars: Double) -> String {
        dollars.formatted(.currency(code: "USD").precision(.fractionLength(dollars < 1 ? 3 : 2)).locale(CoreLanguage.locale))
    }
}
