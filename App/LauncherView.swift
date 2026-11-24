import SwiftUI
import UniformTypeIdentifiers
import WhyNodeCore

/// WhyNode 시작 화면: 새 프로젝트 · 프로젝트 열기, 저장 위치의 프로젝트 목록 (SPEC 2.1)
struct LauncherView: View {
    @Environment(\.openDocument) private var openDocument
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(SettingsStore.self) private var settings

    @State private var projects: [ProjectEntry] = []
    @State private var importing = false
    @State private var errorTitle: LocalizedStringKey = "Couldn't Open"
    @State private var errorMessage: String?
    @State private var showOnboarding = false

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
                action("Open Project", systemImage: "folder") { importing = true }
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    // 설정은 메뉴 막대 WhyNode > 설정(⌘,)으로 연다.
                    Label(settings.ai?.summary ?? tr("AI is not connected"), systemImage: settings.isConfigured ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(settings.isConfigured ? Color.secondary : Color.orange)
                        .lineLimit(2)
                }
            }
            .padding(32)
            .frame(width: 300)

            Divider()

            projectBrowser
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 860, minHeight: 520)
        .task(id: settings.projectFolder) { await loadProjects() }
        .onAppear {
            // 첫 실행에는 AI 연결부터 묻는다. 이후에는 저장된 설정을 그대로 쓴다.
            showOnboarding = !settings.isConfigured
            settings.warmUp()
        }
        .sheet(isPresented: $showOnboarding) {
            AISetupView(mode: .onboarding) { showOnboarding = false }
                .environment(settings)
                .interactiveDismissDisabled()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.whynode]) { result in
            switch result {
            case .success(let url): open(url)
            case .failure(let error): show("Couldn't Open", error.localizedDescription)
            }
        }
        .alert(errorTitle, isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
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

    private func show(_ title: LocalizedStringKey, _ message: String) {
        errorTitle = title
        errorMessage = message
    }

    /// 저장 위치에 파일을 먼저 만들어 연다(선저장).
    private func create(_ map: MindMap, name: String) {
        Task {
            do {
                try await ProjectCreator(settings: settings, openDocument: openDocument).create(map, name: name)
                dismissWindow(id: LauncherView.windowId)
            } catch {
                show("Couldn't Create", error.localizedDescription)
            }
        }
    }

    // 프로젝트 목록

    /// 저장 위치의 프로젝트를 Finder처럼 카드로 보여 준다. 카드마다 첫 노드의 주제와 노드 수 · 수정 시각을 적는다.
    private var projectBrowser: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Projects").font(.headline)
                    Text(verbatim: settings.projectFolder.path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button { Task { await loadProjects() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly)
                    .help("Refresh")
                Button { NSWorkspace.shared.open(settings.projectFolder) } label: { Label("Show in Finder", systemImage: "folder") }
                    .labelStyle(.iconOnly)
                    .help("Show in Finder")
            }
            .padding(.horizontal, 24)

            if projects.isEmpty {
                ContentUnavailableView("No Projects", systemImage: "square.grid.2x2", description: Text("Create a new project to get started."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 14)], spacing: 14) {
                        ForEach(projects) { project in
                            ProjectCard(project: project) { open(project.url) }
                                .contextMenu {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                                    Divider()
                                    Button("Move to Trash", role: .destructive) { trash(project) }
                                }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        .padding(.top, 24)
    }

    /// 프로젝트 파일을 휴지통으로 옮긴다. 휴지통에서 되살릴 수 있어 따로 묻지 않는다. 열려 있는 프로젝트는 먼저 닫게 한다.
    private func trash(_ project: ProjectEntry) {
        let target = project.url.standardizedFileURL
        if NSDocumentController.shared.documents.contains(where: { $0.fileURL?.standardizedFileURL == target }) {
            show("Couldn't Delete", tr("Close the project before deleting it."))
            return
        }
        do {
            try FileManager.default.trashItem(at: project.url, resultingItemURL: nil)
            projects.removeAll { $0.id == project.id }
        } catch {
            show("Couldn't Delete", error.localizedDescription)
        }
    }

    /// 파일을 읽는 일은 화면 밖에서 하고, 최근에 고친 순으로 놓는다.
    private func loadProjects() async {
        let folder = settings.projectFolder
        projects = await Task.detached { ProjectEntry.scan(folder) }.value
    }

    private func open(_ url: URL) {
        Task {
            do {
                try await openDocument(at: url)
                dismissWindow(id: LauncherView.windowId)
            } catch {
                show("Couldn't Open", error.localizedDescription)
                await loadProjects()
            }
        }
    }
}

/// 저장 위치에 있는 프로젝트 파일 하나
struct ProjectEntry: Identifiable, Sendable {
    let url: URL
    let preview: ProjectPreview
    let modified: Date

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    nonisolated static func scan(_ folder: URL) -> [ProjectEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension == "whynode" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url), let preview = WhyNodeCodec.preview(data) else { return nil }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return ProjectEntry(url: url, preview: preview, modified: modified)
            }
            .sorted { $0.modified > $1.modified }
    }
}

/// 프로젝트 카드: 첫 노드의 주제를 크게, 파일 이름과 노드 수 · 수정 시각을 작게 보여 준다.
struct ProjectCard: View {
    let project: ProjectEntry
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Group {
                    if project.preview.topic.isEmpty {
                        Text("No topic yet").foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: project.preview.topic)
                    }
                }
                .font(.headline)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                // 파일 이름은 주제를 따르므로, 사용자가 다르게 바꾼 경우에만 보여 준다.
                if project.name != ProjectFiles.sanitized(project.preview.topic) {
                    Text(verbatim: project.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                (Text("^[\(project.preview.nodeCount) node](inflect: true)") + Text(verbatim: " · ") + Text(project.modified, format: .relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.separator))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
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
