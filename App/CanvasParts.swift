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
/// 스페이스(시뮬레이션 켜기) 눌림 감지. 평소에는 키 이벤트로 받고, 노드를 끌거나 화면을 미는 중에는
/// 키 이벤트가 늦게 올 수 있어 키보드 상태를 직접 읽는다. 눌림 한 번에 한 번만 알린다.
final class SpaceKey {
    private(set) var isDown = false
    var onPress: (() -> Void)?
    private var timer: Timer?
    private static let keyCode: CGKeyCode = 49

    /// 키 이벤트로 눌렸을 때. 이미 눌린 상태로 알고 있으면 다시 알리지 않는다.
    func keyDown() {
        guard !isDown else { return }
        isDown = true
        onPress?()
    }

    func keyUp() {
        isDown = false
    }

    /// 끌기 · 밀기가 시작되면 부른다. 여러 번 불러도 하나만 돈다.
    func startPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        if CGEventSource.keyState(.combinedSessionState, key: Self.keyCode) {
            keyDown()
        } else {
            keyUp()
        }
    }
}

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
                // 추가 질문 목록 같은 스크롤 영역 위에서는 그 영역이 스크롤되게 넘긴다.
                if let content = window.contentView,
                   let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
                   hit.enclosingScrollView != nil {
                    return event
                }
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

/// 뷰가 놓인 창을 알려 준다.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// 캔버스 키 · 마우스 입력: ⌫ · ⌦(포커스 노드 삭제), Esc(편집 패널 닫기), 스페이스(시뮬레이션 켜기), 우클릭 · Control+클릭(노드 편집 패널 열기).
/// 이 뷰가 놓인 창이 키 창이고, 글자 입력 중이 아니며, 시트 · 알림이 없을 때만 처리한다.
/// 메뉴 단축키로 두면 입력칸의 글자 지우기까지 가로채므로 이벤트를 직접 거른다.
struct CanvasEventMonitor: NSViewRepresentable {
    /// 각 처리기는 처리했으면 true를 돌려 이벤트를 소비한다.
    let onDelete: () -> Bool
    let onEscape: () -> Bool
    let onSpace: () -> Bool
    let onSpaceUp: () -> Void
    /// 캔버스 좌표(왼쪽 위 원점)를 받는다.
    let onSecondaryClick: (CGPoint) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        update(view)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        update(view)
    }

    private func update(_ view: MonitorView) {
        view.onDelete = onDelete
        view.onEscape = onEscape
        view.onSpace = onSpace
        view.onSpaceUp = onSpaceUp
        view.onSecondaryClick = onSecondaryClick
    }

    final class MonitorView: NSView {
        var onDelete: (() -> Bool)?
        var onEscape: (() -> Bool)?
        var onSpace: (() -> Bool)?
        var onSpaceUp: (() -> Void)?
        var onSecondaryClick: ((CGPoint) -> Bool)?
        nonisolated(unsafe) private var monitor: Any?
        /// 51: Delete(⌫), 117: Forward Delete(⌦)
        private static let deleteKeys: Set<UInt16> = [51, 117]
        private static let escapeKey: UInt16 = 53
        private static let spaceKey: UInt16 = 49

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.attachedSheet == nil else { return event }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
                switch event.type {
                case .keyDown:
                    guard window.isKeyWindow, modifiers.isEmpty, !(window.firstResponder is NSText) else { return event }
                    if Self.deleteKeys.contains(event.keyCode) { return self.onDelete?() == true ? nil : event }
                    if event.keyCode == Self.escapeKey { return self.onEscape?() == true ? nil : event }
                    // 누르고 있어도 켜고 끄기를 반복하지 않는다.
                    if event.keyCode == Self.spaceKey { return event.isARepeat || self.onSpace?() == true ? nil : event }
                    return event
                case .keyUp:
                    // 입력칸 · 다른 창과 상관없이 떼면 눌림 상태를 푼다.
                    if event.keyCode == Self.spaceKey { self.onSpaceUp?() }
                    return event
                case .rightMouseDown:
                    return self.secondaryClick(event) ? nil : event
                case .leftMouseDown where modifiers == .control:
                    return self.secondaryClick(event) ? nil : event
                default:
                    return event
                }
            }
        }

        private func secondaryClick(_ event: NSEvent) -> Bool {
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return false }
            return onSecondaryClick?(point) == true
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
#endif
