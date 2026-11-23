import SwiftUI
import UniformTypeIdentifiers

@main
struct WhyNodeApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { WhyNodeDocument() }) { file in
            MapScreen(document: file.document)
        }
    }
}

extension UTType {
    nonisolated static let whynode = UTType(exportedAs: "com.pargame.whynode", conformingTo: .json)
}
