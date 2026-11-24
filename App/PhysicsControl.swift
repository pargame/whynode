import SwiftUI
import WhyNodeCore

/// 캔버스 오른쪽 아래의 시뮬레이션 버튼 (SPEC 2.6). 평소에는 버튼만 보이고,
/// 마우스를 올리거나 화살표를 누르면 위로 펼쳐지며 조절값 슬라이더 · 입력칸이 나타난다.
struct PhysicsControl: View {
    @Binding var settings: PhysicsSettings
    let isRunning: Bool
    let onToggle: () -> Void

    @State private var hovering = false
    @State var keepsOpen = false
    @State private var closeTask: Task<Void, Never>?
    @FocusState private var editing: Bool

    /// 입력칸을 고치는 중에는 마우스가 벗어나도 접지 않는다.
    private var expanded: Bool { hovering || keepsOpen || editing }
    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if expanded {
                panel
                    .padding([.horizontal, .top], 16)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
            }
            header
        }
        .frame(width: expanded ? 300 : nil, alignment: .trailing)
        .background(.regularMaterial, in: shape)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .onHover(perform: hover)
        .animation(.spring(duration: 0.35, bounce: 0.18), value: expanded)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                Label(isRunning ? "Stop" : "Simulate", systemImage: isRunning ? "stop.fill" : "atom")
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .symbolEffect(.rotate, isActive: isRunning)

            Button { keepsOpen.toggle() } label: {
                Image(systemName: "chevron.up")
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(keepsOpen ? "Collapse controls" : "Keep controls open")
        }
        .font(.callout.weight(.medium))
        .padding(4)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Repulsion", value: $settings.repel, range: PhysicsSettings.range, step: 0.1)
            row("Tension", value: $settings.tension, range: PhysicsSettings.range, step: 0.1)
            Text("The root stays fixed. Repulsion spreads nodes apart, and tension pulls linked nodes together.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reset to Defaults") { settings = .default }
                .controlSize(.small)
                .disabled(settings == .default)
                .frame(maxWidth: .infinity)
        }
    }

    private func row(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium))
            HStack(spacing: 10) {
                // 눈금 표시 없이 매끄럽게 움직이고, 값만 단위에 맞춰 반올림한다.
                Slider(value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = ($0 / step).rounded() * step }
                ), in: range)
                // 직접 입력한 값은 범위 안으로 맞춘다.
                TextField(title, value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
                ), format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
                .focused($editing)
            }
        }
    }

    /// 경계를 살짝 벗어났다 돌아오는 정도로는 접히지 않도록 닫기를 잠깐 늦춘다.
    private func hover(_ inside: Bool) {
        closeTask?.cancel()
        if inside {
            hovering = true
        } else {
            closeTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                if !Task.isCancelled { hovering = false }
            }
        }
    }
}

