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
                .environment(\.locale, settings.language.locale)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)
        // 윈도우 메뉴에는 넣지 않는다. 파일 > 프로젝트 보기(⇧⌘O)로 연다.
        .commandsRemoved()

        DocumentGroup(newDocument: { WhyNodeDocument() }) { file in
            MapScreen(document: file.document)
                .environment(settings)
                .environment(\.locale, settings.language.locale)
        }
        .defaultLaunchBehavior(.suppressed)
        // 문서 창은 화면의 사용 가능한 영역을 가득 채운 창으로 연다.
        .defaultWindowPlacement { _, context in
            let visible = context.defaultDisplay.visibleRect
            return WindowPlacement(visible.origin, size: visible.size)
        }
        .commands {
            NewProjectCommands(settings: settings)
            UndoCommands(settings: settings)
            HelpCommands(settings: settings)
        }

        // 메뉴 막대 도움말 > WhyNode 도움말 (⌘?)
        Window(tr("WhyNode Help"), id: HelpView.windowId) {
            HelpView()
                .environment(settings)
                .environment(\.locale, settings.language.locale)
        }
        .windowResizability(.contentMinSize)
        // 도움말 메뉴(⌘?)와 겹치므로 윈도우 메뉴에는 넣지 않는다.
        .commandsRemoved()

        // 메뉴 막대 WhyNode > 설정… (⌘,)
        Settings {
            AISetupView(mode: .settings)
                .environment(settings)
                .environment(\.locale, settings.language.locale)
        }
        #else
        DocumentGroup(newDocument: { WhyNodeDocument() }) { file in
            MapScreen(document: file.document)
                .environment(settings)
                .environment(\.locale, settings.language.locale)
        }

        DocumentGroupLaunchScene("WhyNode") {
            NewDocumentButton("New Project")
        } background: {
            LinearGradient(colors: [.blue.opacity(0.25), .indigo.opacity(0.15)], startPoint: .top, endPoint: .bottom)
        }
        #endif
    }
}

extension FocusedValues {
    @Entry var documentUndo: DocumentUndoState?
}

/// 문서 창의 실행 취소 상태. AI 답변을 기다리는 동안에는 실행 취소 · 다시 실행을 막는다(SPEC 6.6).
struct DocumentUndoState {
    /// 이 문서에 진행 중인 AI 요청이 있는지
    let busy: Bool
    let undoTitle: String?
    let redoTitle: String?
}

#if os(macOS)
/// 편집 > 실행 취소 · 다시 실행. 실제 처리는 응답 체인(입력칸이면 글자, 문서면 문서)에 맡기고,
/// AI 응답을 기다리는 문서에서는 끈다. 도중에 끊긴 요청은 사용량을 알 수 없어 토큰이 새기 때문이다.
struct UndoCommands: Commands {
    let settings: SettingsStore
    @FocusedValue(\.documentUndo) private var state

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            let _ = settings.language
            Button {
                NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            } label: {
                Text(verbatim: state?.undoTitle ?? tr("Undo"))
            }
            .keyboardShortcut("z")
            .disabled(state?.busy == true)
            Button {
                NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
            } label: {
                Text(verbatim: state?.redoTitle ?? tr("Redo"))
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(state?.busy == true)
        }
    }
}
#endif

extension UTType {
    nonisolated static let whynode = UTType(exportedAs: "com.pargame.whynode", conformingTo: .json)
}
