#if os(macOS) && DEBUG
import AppKit
import SwiftUI
import WhyNodeCore

/// 디버그 빌드 전용: `--render-snapshots <폴더>`로 실행하면 대표 노드 상태를 라이트 · 다크로 PNG 렌더링하고 종료한다.
/// 창을 띄우지 않고 색 대비와 배치를 확인하기 위한 도구다.
enum SnapshotRenderer {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--render-snapshots"), flag + 1 < args.count else { return }
        let directory = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                render(scheme: name == "dark" ? .dark : .light, to: directory.appendingPathComponent("nodes-\(name).png"))
            }
        }
        exit(0)
    }

    private static func render(scheme: ColorScheme, to url: URL) {
        let now = Date()
        var map = MindMap.new(now: now)
        map.setRootQuestion("레이트레이싱", now: now)
        let answered = ValidatedAnswer(
            answer: "레이트레이싱은 카메라에서 화면 픽셀마다 **광선**을 쏘아, 물체와 부딪힌 지점에서 반사 · 굴절 · 그림자 광선을 다시 추적해 빛의 경로를 계산하는 렌더링 방식입니다. `O(n log n)` 가속 구조로 충돌 검사를 줄입니다.",
            summary: "광선을 추적해 빛을 계산하는 렌더링",
            suggestions: ["광선과 물체의 충돌점은 어떻게 빠르게 찾을까?", "반사 광선은 몇 번까지 추적해야 할까?", "그림자 광선은 왜 필요할까?"],
            refs: [], removed: []
        )
        map.applyAnswer(map.rootId, answered, generation: MockProvider().generation(), now: now)
        let pending = map.addChild(of: map.rootId, suggestion: map.root.suggestions[0].id, now: now)!
        let failed = map.addCustomChild(of: map.rootId, question: "BVH는 어떻게 만들까?", now: now)!
        map.failRequest(failed, message: "AI 응답 시간이 초과됐습니다.", now: now)

        let content = HStack(alignment: .center, spacing: 28) {
            NodeBubble(node: map.root, isExpanded: true, isFocused: true, isDimmed: false, isSuggesting: false, onRetry: {}, onCustomQuestion: {})
            VStack(spacing: 24) {
                NodeBubble(node: map.root, isExpanded: false, isFocused: false, isDimmed: false, isSuggesting: false, onRetry: {}, onCustomQuestion: {})
                NodeBubble(node: map[pending]!, isExpanded: false, isFocused: false, isDimmed: false, isSuggesting: false, onRetry: {}, onCustomQuestion: {})
            }
            VStack(spacing: 24) {
                NodeBubble(node: MindMap.new(now: now).root, isExpanded: false, isFocused: false, isDimmed: false, isSuggesting: false, onRetry: {}, onCustomQuestion: {})
                NodeBubble(node: map[failed]!, isExpanded: true, isFocused: false, isDimmed: false, isSuggesting: false, onRetry: {}, onCustomQuestion: {})
            }
            Text("추가 질문 칩 예시")
                .font(.callout)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .layeredFill(Capsule(), tint: Color.accentColor.opacity(0.14))
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.6)))
        }
        .padding(32)
        .background(Theme.canvas)
        .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }
}
#endif
