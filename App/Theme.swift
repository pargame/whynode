import SwiftUI
import WhyNodeCore

/// 라이트 · 다크 모두에서 구분되는 의미 색. 하드코딩한 흰색 · 회색은 쓰지 않는다.
enum Theme {
    #if os(macOS)
    static let canvas = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    #else
    static let canvas = Color(uiColor: .secondarySystemBackground)
    static let surface = Color(uiColor: .systemBackground)
    static let separator = Color(uiColor: .separator)
    #endif

    /// 선은 노드보다 한발 물러서 보이도록 연하게 둔다.
    static let edge = Color.secondary.opacity(0.45)
    static let refEdge = Color.accentColor.opacity(0.45)
    /// 선 굵기(pt). 화면 좌표로 그리므로 확대 · 축소와 상관없이 같은 굵기로 보인다.
    static let edgeWidth: CGFloat = 1
    /// 호버한 노드와 이웃의 테두리 · 선에 번지는 빛
    static let glow = Color.accentColor
    /// 호버 빛이 은은하게 켜지고 꺼지는 시간
    static let glowAnimation = Animation.easeInOut(duration: 0.45)

    /// 불투명 바탕 위에 겹치는 상태 색
    static func tint(for status: NodeStatus) -> Color {
        switch status {
        case .empty: .secondary.opacity(0.12)
        case .pending: .yellow.opacity(0.18)
        case .done: .clear
        case .error: .red.opacity(0.14)
        }
    }

    static func border(for status: NodeStatus, focused: Bool) -> Color {
        if focused { return .accentColor }
        switch status {
        case .pending: return .orange.opacity(0.8)
        case .error: return .red.opacity(0.8)
        case .empty, .done: return separator
        }
    }
}

extension Font {
    /// 글자 크기 설정(`SettingsStore.textScale`)을 반영한 시스템 글꼴. 기준 크기는 플랫폼의 텍스트 스타일 크기를 따른다.
    static func scaled(_ style: Font.TextStyle, _ scale: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: baseSize(style) * scale, weight: weight, design: design)
    }

    private static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        #if os(macOS)
        typealias PlatformFont = NSFont
        #else
        typealias PlatformFont = UIFont
        #endif
        let textStyle: PlatformFont.TextStyle = switch style {
        case .caption: .caption1
        case .caption2: .caption2
        case .footnote: .footnote
        case .subheadline: .subheadline
        case .body: .body
        default: .callout
        }
        return PlatformFont.preferredFont(forTextStyle: textStyle).pointSize
    }
}

extension View {
    /// 불투명 바탕을 먼저 깔고 상태 색을 겹쳐, 뒤의 선이 글자 뒤로 비치지 않게 한다.
    func layeredFill<S: Shape>(_ shape: S, tint: Color) -> some View {
        background {
            shape.fill(Theme.surface).overlay(shape.fill(tint))
        }
    }
}
