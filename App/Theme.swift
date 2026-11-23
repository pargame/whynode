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

    static let edge = Color.secondary.opacity(0.7)
    static let refEdge = Color.accentColor.opacity(0.7)

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

extension View {
    /// 불투명 바탕을 먼저 깔고 상태 색을 겹쳐, 뒤의 선이 글자 뒤로 비치지 않게 한다.
    func layeredFill<S: Shape>(_ shape: S, tint: Color) -> some View {
        background {
            shape.fill(Theme.surface).overlay(shape.fill(tint))
        }
    }
}
