import QuartzCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 두 점을 잇는 선. 끝점이 애니메이션되므로 화면 이동 · 노드 이동 때 노드와 같은 박자로 움직인다.
struct EdgeShape: Shape {
    var from: CGPoint
    var to: CGPoint

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData> {
        get { AnimatablePair(from.animatableData, to.animatableData) }
        set {
            from.animatableData = newValue.first
            to.animatableData = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }
}

/// 화면에 그릴 선 하나
struct EdgeItem: Identifiable {
    enum Kind {
        case tree, ref
    }

    let id: String
    let kind: Kind
    let from: CGPoint
    let to: CGPoint
    let dimmed: Bool
    /// 호버한 노드에 닿은 선
    var highlighted = false
}

/// 화면 주사율에 맞춰 매 프레임 호출한다. 시뮬레이션이 도는 동안만 켠다.
final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private var onFrame: (() -> Void)?

    func start(_ onFrame: @escaping () -> Void) {
        stop()
        self.onFrame = onFrame
        #if os(macOS)
        link = NSScreen.main?.displayLink(target: self, selector: #selector(step))
        #else
        link = CADisplayLink(target: self, selector: #selector(step))
        #endif
        link?.add(to: .main, forMode: .common)
    }

    func stop() {
        link?.invalidate()
        link = nil
        onFrame = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        onFrame?()
    }
}

#if os(macOS)
/// 트랙패드 두 손가락 스크롤 · 마우스 휠로 캔버스를 움직인다. 시스템이 보내는 관성 이벤트를 그대로 받아 손을 뗀 뒤에도 부드럽게 미끄러진다.
/// 이 뷰가 놓인 창의 스크롤만 처리한다.
struct ScrollPanMonitor: NSViewRepresentable {
    let onScroll: (CGSize) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onScroll = onScroll
    }

    final class MonitorView: NSView {
        var onScroll: ((CGSize) -> Void)?
        nonisolated(unsafe) private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.attachedSheet == nil
                else { return event }
                let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                self.onScroll?(CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor))
                return nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// ⌫ · ⌦ 키로 포커스 노드를 지운다. 이 뷰가 놓인 창이 키 창이고, 글자 입력 중이 아니며, 시트 · 알림이 없을 때만 처리한다.
/// 메뉴 단축키로 두면 입력칸의 글자 지우기까지 가로채므로 이벤트를 직접 거른다.
struct DeleteKeyMonitor: NSViewRepresentable {
    /// 처리했으면 true를 돌려 이벤트를 소비한다.
    let onDelete: () -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onDelete = onDelete
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onDelete = onDelete
    }

    final class MonitorView: NSView {
        var onDelete: (() -> Bool)?
        nonisolated(unsafe) private var monitor: Any?
        /// 51: Delete(⌫), 117: Forward Delete(⌦)
        private static let keyCodes: Set<UInt16> = [51, 117]

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      window.attachedSheet == nil,
                      Self.keyCodes.contains(event.keyCode),
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad]).isEmpty,
                      !(window.firstResponder is NSText)
                else { return event }
                return self.onDelete?() == true ? nil : event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
#endif
