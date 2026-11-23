#if os(macOS)
import AppKit
import SwiftUI
import WhyNodeCore

/// 새 프로젝트를 만들자마자 파일로 저장한다(선저장). 이름 없는 문서로 두지 않아, 앱을 끌 때 저장 · 삭제를 묻지 않는다.
enum ProjectFiles {
    /// 새 프로젝트가 저장되는 폴더: ~/Documents/WhyNode
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhyNode", isDirectory: true)
    }

    /// `map`을 `name.whynode`로 저장하고 경로를 돌려준다. 같은 이름이 있으면 `name 2`, `name 3`…으로 피한다.
    static func create(_ map: MindMap, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = sanitized(name)
        var url = folder.appendingPathComponent(base).appendingPathExtension("whynode")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(number)").appendingPathExtension("whynode")
            number += 1
        }
        try WhyNodeCodec.encode(map.file).write(to: url, options: .withoutOverwriting)
        return url
    }

    /// 파일 이름에 쓸 수 없는 문자를 바꾸고 너무 길면 자른다.
    private static func sanitized(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(cleaned.prefix(60))
        return short.isEmpty ? "새 프로젝트" : short
    }
}

/// 새 프로젝트 만들기. 설정(`SettingsStore.preSavesNewProjects`)이 켜져 있으면 파일을 먼저 만들고 열며,
/// 꺼져 있으면 이름 없는 문서로 연다(끌 때 저장 · 삭제를 묻는 macOS 기본 동작).
@MainActor
struct ProjectCreator {
    let settings: SettingsStore
    let newDocument: NewDocumentAction
    let openDocument: OpenDocumentAction

    func create(_ map: MindMap = .new(), name: String = "새 프로젝트") async throws {
        guard settings.preSavesNewProjects else {
            newDocument { WhyNodeDocument(map: map) }
            return
        }
        let url = try ProjectFiles.create(map, name: name)
        try await openDocument(at: url)
    }
}

/// 파일 > 새 프로젝트 (⌘N)도 시작 화면과 같은 방식으로 만든다.
struct NewProjectCommands: Commands {
    let settings: SettingsStore
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("새 프로젝트") {
                let creator = ProjectCreator(settings: settings, newDocument: newDocument, openDocument: openDocument)
                Task { try? await creator.create() }
            }
            .keyboardShortcut("n")
        }
    }
}
#endif
