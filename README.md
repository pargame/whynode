# WhyNode

**English** | [한국어](README.ko.md)

WhyNode is a native macOS app for building interactive knowledge mind maps through follow-up questions. Each node pairs a single question with a focused AI answer and suggests the next questions to explore. iPadOS support is paused until official provider sign-in is available; the code keeps its platform branches.


## Project Structure

| Path | Description |
| :--- | :--- |
| `Packages/WhyNodeCore` | Headless Swift core package: node model, `.whynode` codec & migration, integrity recovery, AI context assembly, response validation, answer formatting, AI providers, and force-directed layout simulation |
| `App` | Multiplatform SwiftUI document app (`DocumentGroup`) |
| `project.yml` | XcodeGen specification (`WhyNode.xcodeproj` is generated from this file and excluded from Git) |

## Prerequisites: AI Connection

WhyNode connects to AI with either an API key or **My CLI**, which uses the subscription of an official CLI signed in on this Mac (macOS only). For My CLI, install the CLI, run it once in a new Terminal window to sign in, then press **Check Again** in Settings (⌘,).

| Provider | CLI | Install | Sign in |
| :--- | :--- | :--- | :--- |
| Anthropic Claude | Claude Code (`claude`) | `curl -fsSL https://claude.ai/install.sh \| bash` (or `brew install --cask claude-code`) | Run `claude` |
| Google Gemini | Antigravity CLI (`agy`) | `curl -fsSL https://antigravity.google/cli/install.sh \| bash` | Run `agy` |

WhyNode looks for the CLI in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`, `~/bin`, and the login shell's `PATH`. Codex CLI is not supported yet; use an OpenAI API key instead.

## AI Connections & Token Optimization

For every request, WhyNode assembles only the tree context relevant to the target node. Because that context is intentionally compact, default CLI system prompts, tool schemas, and global user rules would otherwise dominate token usage. The settings below strip that overhead.

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
- WhyNode never reads or reuses subscription tokens directly; CLI authentication is delegated entirely to the official CLI.

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
