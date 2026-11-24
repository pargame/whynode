import SwiftUI
import UniformTypeIdentifiers
import WhyNodeCore

/// WhyNode 시작 화면: 새 프로젝트 · 프로젝트 열기 · 최근 프로젝트 · v1 가져오기 (SPEC 2.1)
struct LauncherView: View {
    @Environment(\.openDocument) private var openDocument
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(SettingsStore.self) private var settings

    @State private var recent: [URL] = []
    @State private var importing: ImportKind?
    @State private var errorMessage: String?
    @State private var showOnboarding = false

    enum ImportKind {
        case open, v1
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                    Text("WhyNode")
                        .font(.largeTitle.bold())
                    Text("A knowledge mind map that grows as you follow your questions")
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 12)

                action("New Project", systemImage: "plus.circle.fill", prominent: true) {
                    create(.new(), name: ProjectFiles.untitledName)
                }
                action("Open Project", systemImage: "folder") { importing = .open }
                action("Import v1 File", systemImage: "square.and.arrow.down") { importing = .v1 }
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    Label(settings.ai?.summary ?? String(localized: "AI is not connected"), systemImage: settings.isConfigured ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(settings.isConfigured ? Color.secondary : Color.orange)
                        .lineLimit(2)
                    Button("Settings") { openSettings() }
                        .controlSize(.small)
                }
            }
            .padding(32)
            .frame(width: 300)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Recent Projects")
                    .font(.headline)
                    .padding(.horizontal, 12)
                if recent.isEmpty {
                    ContentUnavailableView("No Recent Projects", systemImage: "clock", description: Text("Create a new project to get started."))
                } else {
                    List(recent, id: \.self) { url in
                        Button { open(url) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.deletingPathExtension().lastPathComponent)
                                Text(url.deletingLastPathComponent().path(percentEncoded: false))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .padding(.vertical, 24)
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 680, minHeight: 420)
        .onAppear {
            loadRecent()
            // 첫 실행에는 AI 연결부터 묻는다. 이후에는 저장된 설정을 그대로 쓴다.
            showOnboarding = !settings.isConfigured
            settings.warmUp()
        }
        .sheet(isPresented: $showOnboarding) {
            AISetupView(mode: .onboarding) { showOnboarding = false }
                .environment(settings)
                .interactiveDismissDisabled()
        }
        .fileImporter(isPresented: importerBinding, allowedContentTypes: importing == .v1 ? [.json] : [.whynode]) { result in
            handleImport(result)
        }
        .alert("Couldn't Open", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    static let windowId = "launcher"

    private func action(_ title: LocalizedStringKey, systemImage: String, prominent: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.large)
        .buttonStyle(prominent ? AnyPrimitiveButtonStyle(.borderedProminent) : AnyPrimitiveButtonStyle(.bordered))
    }

    private var importerBinding: Binding<Bool> {
        Binding(get: { importing != nil }, set: { if !$0 { importing = nil } })
    }

    /// 저장 위치에 파일을 먼저 만들어 연다(선저장).
    private func create(_ map: MindMap, name: String) {
        Task {
            do {
                try await ProjectCreator(settings: settings, openDocument: openDocument).create(map, name: name)
                dismissWindow(id: LauncherView.windowId)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadRecent() {
        #if os(macOS)
        recent = NSDocumentController.shared.recentDocumentURLs.filter { $0.pathExtension == "whynode" }
        #endif
    }

    private func open(_ url: URL) {
        Task {
            do {
                try await openDocument(at: url)
                dismissWindow(id: LauncherView.windowId)
            } catch {
                errorMessage = error.localizedDescription
                loadRecent()
            }
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        let kind = importing
        importing = nil
        do {
            let url = try result.get()
            switch kind {
            case .open:
                open(url)
            case .v1:
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let (map, _) = try V1Import.convert(Data(contentsOf: url))
                create(map, name: map.root.question)
            case nil:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 조건에 따라 버튼 스타일을 바꾸기 위한 타입 지우기
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
