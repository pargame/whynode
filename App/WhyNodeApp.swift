import SwiftUI
import UniformTypeIdentifiers

@main
struct WhyNodeApp: App {
    @State private var settings = SettingsStore()

    init() {
        #if os(macOS) && DEBUG
        SnapshotRenderer.runIfRequested()
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        // 앱을 켜면 파일 선택 창 대신 WhyNode 시작 화면을 띄운다.
        Window("WhyNode", id: LauncherView.windowId) {
            LauncherView()
                .environment(settings)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)

        DocumentGroup(newDocument: { WhyNodeDocument() }) { file in
            MapScreen(document: file.document)
                .environment(settings)
        }
        .defaultLaunchBehavior(.suppressed)
        // 문서 창은 화면의 사용 가능한 영역을 가득 채운 창으로 연다.
        .defaultWindowPlacement { _, context in
            let visible = context.defaultDisplay.visibleRect
            return WindowPlacement(visible.origin, size: visible.size)
        }
        // 메뉴 막대 보기 > 글자 크게 (⌘=) · 글자 작게 (⌘-) · 기본 글자 크기 (⌘0)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("글자 크게") { settings.stepTextScale(1) }
                    .keyboardShortcut("=")
                    .disabled(settings.textScale >= SettingsStore.textScaleRange.upperBound)
                Button("글자 작게") { settings.stepTextScale(-1) }
                    .keyboardShortcut("-")
                    .disabled(settings.textScale <= SettingsStore.textScaleRange.lowerBound)
                Button("기본 글자 크기") { settings.textScale = 1 }
                    .keyboardShortcut("0")
                Divider()
            }
        }

        // 메뉴 막대 WhyNode > 설정… (⌘,)
        Settings {
            AISetupView(mode: .settings)
                .environment(settings)
        }
        #else
        DocumentGroup(newDocument: { WhyNodeDocument() }) { file in
            MapScreen(document: file.document)
                .environment(settings)
        }

        DocumentGroupLaunchScene("WhyNode") {
            NewDocumentButton("새 프로젝트")
        } background: {
            LinearGradient(colors: [.blue.opacity(0.25), .indigo.opacity(0.15)], startPoint: .top, endPoint: .bottom)
        }
        #endif
    }
}

extension UTType {
    nonisolated static let whynode = UTType(exportedAs: "com.pargame.whynode", conformingTo: .json)
}
