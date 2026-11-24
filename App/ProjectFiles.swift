#if os(macOS)
import AppKit
import SwiftUI
import WhyNodeCore

/// 새 프로젝트를 만들자마자 파일로 저장한다(선저장). 이름 없는 문서로 두지 않아, 앱을 끌 때 저장 · 삭제를 묻지 않는다.
enum ProjectFiles {
    /// 기본 저장 폴더: ~/Documents/WhyNode. 설정에서 바꿀 수 있다(`SettingsStore.projectFolder`).
    static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhyNode", isDirectory: true)
    }

    /// `map`을 `folder/name.whynode`로 저장하고 경로를 돌려준다. 같은 이름이 있으면 `name 2`, `name 3`…으로 피한다.
    static var untitledName: String { tr("New Project") }
    /// 언어를 바꿔도 예전 언어로 붙은 자동 이름을 알아보도록 두 언어 이름을 모두 둔다.
    static let untitledNames = ["New Project", "새 프로젝트"]

    static func create(_ map: MindMap, name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = availableURL(for: name, in: folder)
        try WhyNodeCodec.encode(map.file).write(to: url, options: .withoutOverwriting)
        return url
    }

    /// `folder`에서 겹치지 않는 `name.whynode` 경로. 있으면 `name 2`, `name 3`…
    static func availableURL(for name: String, in folder: URL) -> URL {
        let base = sanitized(name)
        var url = folder.appendingPathComponent(base).appendingPathExtension("whynode")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(number)").appendingPathExtension("whynode")
            number += 1
        }
        return url
    }

    /// 파일 이름이 앱이 자동으로 붙인 이름인지. `새 프로젝트`나 이전 주제(뒤에 ` 2` 같은 번호 포함)면 자동 이름으로 본다.
    /// 사용자가 직접 바꾼 이름은 주제가 바뀌어도 건드리지 않는다.
    static func isAutoName(_ fileName: String, previousTopic: String) -> Bool {
        let candidates = untitledNames + [untitledName, sanitized(previousTopic)]
        return candidates.contains { base in
            fileName == base || (fileName.hasPrefix(base + " ") && Int(fileName.dropFirst(base.count + 1)) != nil)
        }
    }

    /// 파일 이름에 쓸 수 없는 문자를 바꾸고 너무 길면 자른다.
    static func sanitized(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(cleaned.prefix(60))
        return short.isEmpty ? untitledName : short
    }

    /// 프로젝트 파일 이름을 루트 주제로 맞춘다. 자동 이름일 때만 바꾸고, 같은 폴더 안에서 옮긴다.
    @MainActor
    static func renameToTopic(_ document: NSDocument?, previousTopic: String, topic: String) {
        guard let document, let url = document.fileURL,
              !topic.isEmpty, sanitized(topic) != url.deletingPathExtension().lastPathComponent,
              isAutoName(url.deletingPathExtension().lastPathComponent, previousTopic: previousTopic)
        else { return }
        let target = availableURL(for: topic, in: url.deletingLastPathComponent())
        document.move(to: target) { _ in }
    }
}

/// 새 프로젝트 만들기. 항상 저장 위치에 파일을 먼저 만들고 연다.
@MainActor
struct ProjectCreator {
    let settings: SettingsStore
    let openDocument: OpenDocumentAction

    func create(_ map: MindMap = .new(), name: String = ProjectFiles.untitledName) async throws {
        let url = try ProjectFiles.create(map, name: name, in: settings.projectFolder)
        try await openDocument(at: url)
    }
}

/// 파일 > 새 프로젝트 (⌘N)도 시작 화면과 같은 방식으로 만든다.
struct NewProjectCommands: Commands {
    let settings: SettingsStore
    @Environment(\.openDocument) private var openDocument

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            let _ = settings.language
            Button(tr("New Project")) {
                let creator = ProjectCreator(settings: settings, openDocument: openDocument)
                Task { try? await creator.create() }
            }
            .keyboardShortcut("n")
        }
    }
}
#endif
