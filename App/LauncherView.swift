import SwiftUI
import UniformTypeIdentifiers
import WhyNodeCore

/// WhyNode 시작 화면: 새 프로젝트 · 프로젝트 열기 · 최근 프로젝트 · v1 가져오기 (SPEC 2.1)
struct LauncherView: View {
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var recent: [URL] = []
    @State private var importing: ImportKind?
    @State private var errorMessage: String?

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
                    Text("질문을 쫓아가며 넓히는 지식 마인드맵")
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 12)

                action("새 프로젝트", systemImage: "plus.circle.fill", prominent: true) {
                    newDocument { WhyNodeDocument() }
                    dismissWindow(id: LauncherView.windowId)
                }
                action("프로젝트 열기…", systemImage: "folder") { importing = .open }
                action("v1 파일 가져오기…", systemImage: "square.and.arrow.down") { importing = .v1 }
                Spacer()
            }
            .padding(32)
            .frame(width: 300)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("최근 프로젝트")
                    .font(.headline)
                    .padding(.horizontal, 12)
                if recent.isEmpty {
                    ContentUnavailableView("최근 프로젝트가 없습니다", systemImage: "clock", description: Text("새 프로젝트를 만들어 시작하세요."))
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
        .onAppear(perform: loadRecent)
        .fileImporter(isPresented: importerBinding, allowedContentTypes: importing == .v1 ? [.json] : [.whynode]) { result in
            handleImport(result)
        }
        .alert("열 수 없습니다", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    static let windowId = "launcher"

    private func action(_ title: String, systemImage: String, prominent: Bool = false, perform: @escaping () -> Void) -> some View {
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
                newDocument { WhyNodeDocument(map: map) }
                dismissWindow(id: LauncherView.windowId)
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
