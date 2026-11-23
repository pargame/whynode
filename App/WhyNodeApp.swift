import SwiftUI
import UniformTypeIdentifiers

@main
struct WhyNodeApp: App {
    var body: some Scene {
        #if os(macOS)
        // 앱을 켜면 파일 선택 창 대신 WhyNode 시작 화면을 띄운다.
        Window("WhyNode", id: LauncherView.windowId) {
            LauncherView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)

        DocumentGroup(newDocument: { WhyNodeDocument() }) { file in
            MapScreen(document: file.document)
        }
        .defaultLaunchBehavior(.suppressed)
        #else
        DocumentGroup(newDocument: { WhyNodeDocument() }) { file in
            MapScreen(document: file.document)
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
