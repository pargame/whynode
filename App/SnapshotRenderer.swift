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
                // 글자를 키워도 노드 크기는 그대로이고 생략(…)만 늘어나는지 본다.
                render(scheme: name == "dark" ? .dark : .light, textScale: 1.5, to: directory.appendingPathComponent("nodes-large-\(name).png"))
                renderPhysics(scheme: name == "dark" ? .dark : .light, to: directory.appendingPathComponent("physics-\(name).png"))
                renderCards(scheme: name == "dark" ? .dark : .light, to: directory.appendingPathComponent("cards-\(name).png"))
                renderStatus(scheme: name == "dark" ? .dark : .light, to: directory.appendingPathComponent("status-\(name).png"))
                renderStylePanel(scheme: name == "dark" ? .dark : .light, to: directory.appendingPathComponent("style-\(name).png"))
            }
        }
        exit(0)
    }

    /// 펼친 시뮬레이션 패널
    private static func renderPhysics(scheme: ColorScheme, to url: URL) {
        let content = HStack(alignment: .bottom, spacing: 24) {
            PhysicsControl(settings: .constant(.default), isRunning: false, onToggle: {})
            PhysicsControl(settings: .constant(.default), isRunning: false, onToggle: {}, keepsOpen: true)
        }
        .padding(32)
        .background(Theme.canvas)
        .environment(\.colorScheme, scheme)
        write(content, to: url)
    }

    /// 시작 화면 프로젝트 카드
    private static func renderCards(scheme: ColorScheme, to url: URL) {
        let folder = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let samples = [
            ProjectEntry(url: folder.appendingPathComponent("레이트레이싱.whynode"), preview: ProjectPreview(topic: "레이트레이싱", nodeCount: 12, updatedAt: nil), modified: Date().addingTimeInterval(-3600)),
            ProjectEntry(url: folder.appendingPathComponent("quantum mechanics.whynode"), preview: ProjectPreview(topic: "quantum mechanics", nodeCount: 4, updatedAt: nil), modified: Date().addingTimeInterval(-86400 * 3)),
            ProjectEntry(url: folder.appendingPathComponent("새 프로젝트.whynode"), preview: ProjectPreview(topic: "", nodeCount: 1, updatedAt: nil), modified: Date()),
        ]
        let content = HStack(spacing: 14) {
            ForEach(samples) { ProjectCard(project: $0) {}.frame(width: 200) }
        }
        .padding(32)
        .background(Theme.canvas)
        .environment(\.colorScheme, scheme)
        write(content, to: url)
    }

    /// 노드 편집 패널
    private static func renderStylePanel(scheme: ColorScheme, to url: URL) {
        var map = MindMap.new()
        map.setRootQuestion("레이트레이싱")
        map.setColors(map.rootId, fill: "green", text: nil)
        let content = HStack(alignment: .top, spacing: 24) {
            NodeStylePanel(node: map.root, canToggleBranch: true, canDelete: true, onTextScale: { _ in }, onSizeScale: { _ in }, onFill: { _ in }, onText: { _ in }, onToggleBranch: {}, onReset: {}, onDelete: {})
            // 사용자 지정 색을 눌렀을 때 펼쳐지는 격자
            PaletteGrid(selected: PaletteGrid.colors[9]) { _ in }
        }
            .padding(32)
            .background(Theme.canvas)
            .environment(\.colorScheme, scheme)
        write(content, to: url)
    }

    /// AI 상태 막대 (연결됨 · 연결 안 됨)
    private static func renderStatus(scheme: ColorScheme, to url: URL) {
        let center = AIRequestCenter()
        let doc = ObjectIdentifier(center)
        let usage = TokenUsage(inputTokens: 9_820, outputTokens: 2_480, costUSD: 0.083, requests: 5)
        let content = VStack(alignment: .leading, spacing: 12) {
            AIStatusBar(center: center, document: doc, projectUsage: usage, connection: "Google Gemini · My CLI", model: AIStatusBar.modelLabel(AISettings(provider: .google, connection: .cli, model: "gemini-4-neon-high")))
            AIStatusBar(center: center, document: doc, projectUsage: .zero, connection: nil)
        }
        .padding(32)
        .background(Theme.canvas)
        .environment(\.colorScheme, scheme)
        write(content, to: url)
    }

    private static func write(_ content: some View, to url: URL) {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }

    private static func render(scheme: ColorScheme, textScale: CGFloat = 1, to url: URL) {
        let now = Date()
        var map = MindMap.new(now: now)
        map.setRootQuestion("레이트레이싱", now: now)
        let answered = ValidatedAnswer(
            answer: """
            **레이트레이싱(RT)**은 화면 픽셀마다 광선을 쏘아 `O(n log n)` 가속 구조로 빛의 경로를 거꾸로 추적합니다.

            1. 카메라에서 1차 광선 발사
            2. 물체와의 충돌점 계산
            3. 반사 · 굴절 · 그림자 광선 분기

            ```diagram
            카메라 → 픽셀 → 물체
            ↓ 충돌점에서 분기
            반사 · 굴절 → 다음 물체
            그림자 → 광원
            ```
            """,
            summary: "광선을 추적해 빛을 계산하는 렌더링",
            suggestions: ["광선과 물체의 충돌점은 어떻게 빠르게 찾을까?", "반사 광선은 몇 번까지 추적해야 할까?", "그림자 광선은 왜 필요할까?"],
            refs: [], removed: []
        )
        map.applyAnswer(map.rootId, answered, generation: MockProvider().generation(), now: now)
        let pending = map.addChild(of: map.rootId, suggestion: map.root.suggestions[0].id, now: now)!
        let failed = map.addCustomChild(of: map.rootId, question: "BVH는 어떻게 만들까? 공간을 나누는 기준과 깊이는 어떻게 정하고, 동적으로 움직이는 물체가 많은 장면에서는 매 프레임 다시 만들어야 할까?", now: now)!
        map.failRequest(failed, message: "AI 응답 시간이 초과됐습니다.", now: now)

        var styledMap = map
        styledMap.setSizeScale(map.rootId, 1.4, now: now)
        styledMap.setColors(map.rootId, fill: "blue", text: "#B00020", now: now)
        let styled = styledMap.root

        func bubble(_ node: Node, focused: Bool, highlighted: Bool = false) -> some View {
            NodeBubble(node: node, isFocused: focused, isDimmed: false, isSuggesting: false, textScale: textScale, isHighlighted: highlighted, onRetry: {})
        }
        // 위쪽을 맞춰 나란히 두고, 질문 중심선(위에서 70pt)을 그어 펼쳐도 질문이 제자리인지 본다.
        let content = HStack(alignment: .top, spacing: 28) {
            bubble(map.root, focused: false)
            bubble(map.root, focused: true)
            bubble(map[pending]!, focused: false)
            bubble(map[failed]!, focused: false)
            bubble(map[failed]!, focused: true)
            bubble(MindMap.new(now: now).root, focused: false)
            // 호버 빛
            bubble(map.root, focused: false, highlighted: true)
            // 꾸민 노드: 크기 1.4, 노드 색 파랑, 글자 색 사용자 지정
            bubble(styled, focused: false)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(.red.opacity(0.5)).frame(height: 1).offset(y: NodeBubble.titleCenter)
        }
        .padding(32)
        .background(Theme.canvas)
        .environment(\.colorScheme, scheme)
        write(content, to: url)
    }
}
#endif
