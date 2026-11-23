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
}

/// 화면 주사율에 맞춰 매 프레임 호출한다. 물리 정리가 도는 동안만 켠다.
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
#endif
