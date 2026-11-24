import SwiftUI
import WhyNodeCore

/// 도움말 창의 섹션
enum HelpSection: String, CaseIterable, Identifiable {
    case start, connect, branching, canvas, styling, ai, shortcuts
    var id: String { rawValue }
}

/// 메뉴 막대 도움말 > WhyNode 도움말(⌘?). 짧은 섹션 일곱 개와 단축키 표.
struct HelpView: View {
    static let windowId = "help"

    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                HelpContent()
            }
            .onAppear { scroll(proxy) }
            .onChange(of: settings.helpSection) { scroll(proxy) }
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 480, idealHeight: 640)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = settings.helpSection else { return }
        withAnimation { proxy.scrollTo(target, anchor: .top) }
        settings.helpSection = nil
    }
}

/// 도움말 본문(스크롤 없이). 스냅샷에서도 쓴다.
struct HelpContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section(.start, "Getting Started", systemImage: "sparkles",
                    "Create a new project and type any topic or question in the first node. WhyNode writes a short answer and suggests follow-up questions below the card. New projects are saved to your projects folder right away and keep saving automatically.")
            section(.connect, "Connecting AI", systemImage: "link",
                    "Choose a provider and connection in Settings (⌘,), then pass the connection test. With My CLI, WhyNode uses the subscription of an official CLI signed in on this Mac. Paste its install command into Terminal, run it once in a new Terminal window to sign in, then press Check Again in Settings.\n\nClaude: `curl -fsSL https://claude.ai/install.sh | bash`, then run `claude`.\nGemini: `curl -fsSL https://antigravity.google/cli/install.sh | bash`, then run `agy`.\n\nWith API Key, paste a key from the provider's console instead. It's stored only in this device's Keychain.")
            section(.branching, "Branching Out", systemImage: "arrow.triangle.branch",
                    "Click a suggestion chip to grow a new node from it. If none fits, use Ask Your Own to type your own question, or 3 Other Questions for fresh ideas (up to 12 unused questions). Regenerate Answer at the bottom of a card asks for a new answer. Dashed lines link related nodes in different branches; Find Links in the toolbar asks the AI to look over the whole map once and add the ones it missed.")
            section(.canvas, "Canvas", systemImage: "hand.draw",
                    "Drag the background, scroll with two fingers, or pinch to move and zoom. Pinching over an expanded node changes only that node's text size. Simulate in the bottom-right corner untangles overlapping nodes; open its arrow to tune repulsion and tension.")
            section(.styling, "Styling Nodes", systemImage: "paintpalette",
                    "Right-click (or Control-click) a node to open its style panel. Text size, node size, node color, and text color change while the panel stays open. The panel also collapses a branch, resets the style, or deletes the node.")
            section(.ai, "AI and Usage", systemImage: "gauge.with.dots.needle.33percent",
                    "The bar at the bottom left shows a status dot (green: ready, orange: answering, gray: not connected), the model in use, and the project's total tokens. Click it for this session's totals and the last request. Undo and deleting are paused while an answer is on its way, because a request cut off midway still uses tokens that can't be counted.")
            shortcuts.id(HelpSection.shortcuts)
        }
        .padding(28)
        .frame(maxWidth: 620, alignment: .leading)
    }

    private func section(_ id: HelpSection, _ title: LocalizedStringKey, systemImage: String, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
            Text(body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .id(id)
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Keyboard Shortcuts", systemImage: "keyboard")
                .font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                row("⌘N", "New Project")
                row("⌘Z  ⌘⇧Z", "Undo and Redo")
                row("⌫", "Delete the focused node")
                row("Esc", "Close the style panel or an empty question input")
                row("⌘=  ⌘-", "Larger or smaller text for all nodes")
                row("⌘0", "Reset the focused node's text size, or the app's when it's unchanged")
                row("⌘,", "Settings")
                row("⌘?", "WhyNode Help")
            }
        }
    }

    private func row(_ keys: String, _ action: LocalizedStringKey) -> some View {
        GridRow {
            Text(verbatim: keys)
                .font(.callout.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            Text(action)
                .foregroundStyle(.secondary)
        }
    }
}

/// 메뉴 막대 도움말 메뉴
struct HelpCommands: Commands {
    let settings: SettingsStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            let _ = settings.language
            Button(tr("WhyNode Help")) { open(.start) }
                .keyboardShortcut("?", modifiers: .command)
            Button(tr("Connecting AI")) { open(.connect) }
            Button(tr("Keyboard Shortcuts")) { open(.shortcuts) }
            Divider()
            Button(tr("Open Projects Folder")) {
                // 첫 프로젝트를 만들기 전이면 폴더가 아직 없을 수 있다.
                try? FileManager.default.createDirectory(at: settings.projectFolder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(settings.projectFolder)
            }
        }
    }

    private func open(_ section: HelpSection) {
        settings.helpSection = section
        openWindow(id: HelpView.windowId)
    }
}
