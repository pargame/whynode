# WhyNode

**English** | [한국어](README.ko.md)

WhyNode is a native macOS and iPadOS app for building interactive knowledge mind maps through follow-up questions. Each node pairs a single question with a focused AI answer and suggests the next questions to explore.

- Concept & UX: [`CONCEPT.md`](CONCEPT.md)
- Specification & Architecture: [`SPEC.md`](SPEC.md)

## Project Structure

| Path | Description |
| :--- | :--- |
| `Packages/WhyNodeCore` | Headless Swift core package: node model, `.whynode` codec & migration, integrity recovery, AI context assembly, response validation, answer formatting, AI providers, and force-directed layout simulation |
| `App` | Multiplatform SwiftUI document app (`DocumentGroup`) |
| `project.yml` | XcodeGen specification (`WhyNode.xcodeproj` is generated from this file and excluded from Git) |

## AI Connections & Token Optimization

For every request, WhyNode assembles only the tree context relevant to the target node (see `SPEC.md` §6.1). Because that context is intentionally compact, default CLI system prompts, tool schemas, and global user rules would otherwise dominate token usage. The settings below strip that overhead.

| Connection | Configuration | Purpose | Measured Impact |
| :--- | :--- | :--- | :--- |
| **Claude CLI** (one-shot per request) | `--system-prompt` override, `--tools ""`, `--strict-mcp-config`, `--setting-sources ""`, `--disable-slash-commands`, `--no-session-persistence` | Excludes Claude Code's built-in prompt, tools, user settings, and MCP servers. | ~18.5k → 1.1k tokens |
| | `DISABLE_PROMPT_CACHING=1` | Disables 1-hour cache writes. Because each node request has unique context, cache writes rarely hit while doubling input token cost. | ~25% cost reduction |
| **agy** (persistent `agy acp`) | `--agent whynode` | Uses a tool-free dedicated agent whose body serves as the system prompt, removing default coding-agent instructions and tool declarations. | ~11.7k → 2.85k tokens |
| | `--gemini-dir <empty temp dir>` | Prevents loading global rules, skills, plugins, and MCP servers from `~/.gemini` and keeps WhyNode sessions out of it. Authentication still works via Keychain. | |
| | Fresh session per request | Prevents conversation history accumulation, cross-branch context bleed, and serialization of concurrent requests. | |
| **API Keys** (Gemini / Claude / OpenAI) | None | Sends only the WhyNode system prompt and assembled node context. | |

- The dedicated `agy` agent file (`<temp>/WhyNodeCLI/.agents/agents/whynode.md`) is regenerated from the active system prompt on every connection; do not edit it manually.
- Claude's `--bare` flag is not used because it cannot read subscription authentication.
- WhyNode never reads or reuses subscription tokens directly (`SPEC.md` §5.2); CLI authentication is delegated entirely to the official CLI.

## Building from Source (macOS)

```zsh
# (Optional) Select a specific Xcode installation without changing xcode-select
# export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Run core unit tests
(cd Packages/WhyNodeCore && swift test)

# Build and launch the macOS app
xcodegen generate
xcodebuild -project WhyNode.xcodeproj -scheme WhyNode -destination 'platform=macOS' -derivedDataPath DerivedData build
open WhyNode.app
```

`WhyNode.app` at the repository root is a local symlink to `DerivedData/Build/Products/Debug/WhyNode.app` (not committed) so it always points to the latest debug build.
