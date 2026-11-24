import SwiftUI
import WhyNodeCore

/// 노드를 우클릭하면 옆에 뜨는 편집 패널: 노드 크기 · 노드 색 · 글자 색, 가지 접기 · 원래대로 · 삭제.
/// 화면 배율과 상관없이 같은 크기로 보이고, 열려 있는 동안 [−][+]를 여러 번 누를 수 있다.
struct NodeStylePanel: View {
    let node: Node
    let canToggleBranch: Bool
    let canDelete: Bool
    let onSizeScale: (Double) -> Void
    let onFill: (String?) -> Void
    let onText: (String?) -> Void
    let onToggleBranch: () -> Void
    let onReset: () -> Void
    let onDelete: () -> Void

    /// 펼쳐진 사용자 지정 색 격자. 한 번에 하나만 펼치고, 패널의 다른 곳을 누르면 접는다.
    @State private var openPalette: ColorRow.Kind?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepper("Node Size", value: node.sizeScale, range: Node.sizeScaleRange, set: onSizeScale)
            ColorRow(kind: .fill, title: "Node Color", selected: node.fillColor, openPalette: $openPalette, onSelect: onFill)
            ColorRow(kind: .text, title: "Text Color", selected: node.textColor, openPalette: $openPalette, onSelect: onText)
            Divider()
            HStack(spacing: 8) {
                if canToggleBranch {
                    Button(node.collapsed ? "Expand Branch" : "Collapse Branch", action: onToggleBranch)
                }
                Button("Reset Style") {
                    closePalette()
                    onReset()
                }
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
        // 버튼이 아닌 빈 곳을 눌러도 펼친 격자를 접는다. 패널 밖을 누르면 패널째 닫힌다.
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { closePalette() }
    }

    /// [−] · [+]는 기호 모양과 상관없이 같은 크기의 정사각형으로 둔다.
    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            closePalette()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func closePalette() {
        guard openPalette != nil else { return }
        withAnimation(.snappy(duration: 0.25)) { openPalette = nil }
    }

    private func stepper(_ title: LocalizedStringKey, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            stepButton("minus", enabled: value > range.lowerBound) { set(value - 0.1) }
            Text(verbatim: value.formatted(.number.precision(.fractionLength(1))) + "×")
                .monospacedDigit()
                .frame(width: 40)
            stepButton("plus", enabled: value < range.upperBound) { set(value + 0.1) }
        }
    }
}

/// 색 한 줄: 기본 · 프리셋 5색 · 사용자 지정. 사용자 지정(무지개 동그라미)을 누르면 패널 안에서 색 격자가 아래로 펼쳐진다.
private struct ColorRow: View {
    enum Kind { case fill, text }

    let kind: Kind
    let title: LocalizedStringKey
    let selected: String?
    @Binding var openPalette: Kind?
    let onSelect: (String?) -> Void

    private var expanded: Bool { openPalette == kind }

    private var isCustom: Bool { selected.map { !NodeColor.presets.contains($0) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            HStack(spacing: 8) {
                swatch(isSelected: selected == nil, action: { pick(nil) }) {
                    Circle().fill(Theme.surface)
                        .overlay(Image(systemName: "slash.circle").foregroundStyle(.secondary))
                }
                .help("Default")
                ForEach(NodeColor.presets, id: \.self) { token in
                    swatch(isSelected: selected == token, action: { pick(token) }) {
                        Circle().fill(Theme.presetColor(token) ?? .gray)
                    }
                }
                Spacer(minLength: 4)
                // 지금 사용자 지정 색이면 그 색을, 아니면 무지개를 보여 준다.
                swatch(isSelected: isCustom || expanded, action: { withAnimation(.snappy(duration: 0.25)) { openPalette = expanded ? nil : kind } }) {
                    if isCustom, let color = Theme.nodeColor(selected) {
                        Circle().fill(color)
                    } else {
                        Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red], center: .center))
                    }
                }
                .help("Custom Color")
            }
            if expanded {
                // 격자에서 고를 때는 펼친 채로 두어, 노드에 적용된 색을 보며 다시 고를 수 있게 한다.
                PaletteGrid(selected: selected) { hex in onSelect(hex) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// 기본 · 프리셋을 고르면 펼친 격자를 접는다(격자 바깥을 누른 것으로 본다).
    private func pick(_ value: String?) {
        onSelect(value)
        withAnimation(.snappy(duration: 0.25)) { openPalette = nil }
    }

    private func swatch(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder fill: () -> some View) -> some View {
        Button(action: action) {
            fill()
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(Theme.separator))
                .padding(2)
                .overlay(Circle().stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

/// 사용자 지정 색 격자: 8가지 색상 × 밝은 · 중간 · 어두운 톤, 그리고 회색 단계
struct PaletteGrid: View {
    let selected: String?
    let onPick: (String) -> Void

    static let hues: [Double] = [0, 30, 52, 120, 175, 215, 270, 325]
    static let tones: [(saturation: Double, brightness: Double)] = [(0.35, 1.0), (0.75, 0.92), (0.85, 0.58)]
    static let colors: [String] = {
        var result: [String] = []
        for tone in tones {
            for hue in hues { result.append(hex(hue: hue / 360, saturation: tone.saturation, brightness: tone.brightness)) }
        }
        for step in 0..<8 {
            let v = 1 - Double(step) / 7
            result.append(NodeColor.hexString(red: v, green: v, blue: v))
        }
        return result
    }()

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 6), count: 8), spacing: 6) {
            ForEach(Self.colors, id: \.self) { hex in
                Button { onPick(hex) } label: {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.nodeColor(hex) ?? .gray)
                        .frame(width: 24, height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Theme.separator))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(selected == hex ? Color.accentColor : .clear, lineWidth: 2).padding(-3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // 격자 안의 틈을 눌렀을 때는 접히지 않게 여기서 받는다.
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {}
    }

    /// HSB를 "#RRGGBB"로 바꾼다.
    static func hex(hue: Double, saturation: Double, brightness: Double) -> String {
        let h = hue * 6
        let sector = Int(h) % 6
        let f = h - Double(Int(h))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        let (r, g, b): (Double, Double, Double) = switch sector {
        case 0: (brightness, t, p)
        case 1: (q, brightness, p)
        case 2: (p, brightness, t)
        case 3: (p, q, brightness)
        case 4: (t, p, brightness)
        default: (brightness, p, q)
        }
        return NodeColor.hexString(red: r, green: g, blue: b)
    }
}
