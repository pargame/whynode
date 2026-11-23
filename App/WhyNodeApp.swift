import SwiftUI
import UniformTypeIdentifiers

@main
struct WhyNodeApp: App {
    @State private var settings = SettingsStore()

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
