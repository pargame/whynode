import SwiftUI
import WhyNodeCore

/// 노드를 우클릭하면 옆에 뜨는 편집 패널: 글자 크기 · 노드 크기 · 노드 색 · 글자 색, 가지 접기 · 원래대로 · 삭제.
/// 화면 배율과 상관없이 같은 크기로 보이고, 열려 있는 동안 [−][+]를 여러 번 누를 수 있다.
struct NodeStylePanel: View {
    let node: Node
    let canToggleBranch: Bool
    let canDelete: Bool
    let onTextScale: (Double) -> Void
    let onSizeScale: (Double) -> Void
    let onFill: (String?) -> Void
    let onText: (String?) -> Void
    let onToggleBranch: () -> Void
    let onReset: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepper("Text Size", value: node.textScale, range: Node.textScaleRange, set: onTextScale)
            stepper("Node Size", value: node.sizeScale, range: Node.sizeScaleRange, set: onSizeScale)
            ColorRow(title: "Node Color", selected: node.fillColor, onSelect: onFill)
            ColorRow(title: "Text Color", selected: node.textColor, onSelect: onText)
            Divider()
            HStack(spacing: 8) {
                if canToggleBranch {
                    Button(node.collapsed ? "Expand Branch" : "Collapse Branch", action: onToggleBranch)
                }
                Button("Reset Style", action: onReset)
                    .disabled(!node.hasCustomStyle)
                Spacer(minLength: 0)
                if canDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                }
            }
            .controlSize(.small)
        }
        .font(.callout)
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.separator))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    private func stepper(_ title: LocalizedStringKey, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button { set(value - 0.1) } label: { Image(systemName: "minus") }
                .disabled(value <= range.lowerBound)
            Text(verbatim: value.formatted(.number.precision(.fractionLength(1))) + "×")
                .monospacedDigit()
                .frame(width: 40)
            Button { set(value + 0.1) } label: { Image(systemName: "plus") }
                .disabled(value >= range.upperBound)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// 색 한 줄: 기본 · 프리셋 5색 · 사용자 지정(누르면 색상 팔레트가 뜨는 네모 색 우물)
private struct ColorRow: View {
    let title: LocalizedStringKey
    let selected: String?
    let onSelect: (String?) -> Void

    private var isCustom: Bool { selected.map { !NodeColor.presets.contains($0) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            HStack(spacing: 8) {
                swatch(nil) {
                    Circle().fill(Theme.surface)
                        .overlay(Image(systemName: "slash.circle").foregroundStyle(.secondary))
                }
                .help("Default")
                ForEach(NodeColor.presets, id: \.self) { token in
                    swatch(token) { Circle().fill(Theme.presetColor(token) ?? .gray) }
                }
                Spacer(minLength: 4)
                ColorPicker(selection: customBinding, supportsOpacity: false) { Text("Custom Color") }
                    .labelsHidden()
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(isCustom ? Color.accentColor : .clear, lineWidth: 2).padding(-3))
                    .help("Custom Color")
            }
        }
    }

    private func swatch(_ token: String?, @ViewBuilder fill: () -> some View) -> some View {
        Button { onSelect(token) } label: {
            fill()
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(Theme.separator))
                .padding(2)
                .overlay(Circle().stroke(selected == token ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    /// 사용자 지정 색 우물. 고르면 "#RRGGBB"로 저장한다.
    private var customBinding: Binding<Color> {
        Binding(
            get: { isCustom ? (Theme.nodeColor(selected) ?? .gray) : .gray },
            set: { color in
                #if os(macOS)
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                onSelect(NodeColor.hexString(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent))
                #else
                let ui = UIColor(color)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                ui.getRed(&r, green: &g, blue: &b, alpha: &a)
                onSelect(NodeColor.hexString(red: r, green: g, blue: b))
                #endif
            }
        )
    }
}
