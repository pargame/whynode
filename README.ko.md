# WhyNode

[English](README.md) | **한국어**

질문 하나와 AI 답변 하나를 하나의 노드로 묶고, 꼬리에 꼬리를 무는 질문으로 나만의 지식 마인드맵을 넓혀 가는 macOS 네이티브 앱입니다. iPadOS는 AI 회사의 공식 로그인을 쓸 수 있을 때까지 보류하며, 코드의 플랫폼 분기는 남겨 두었습니다.

- 서비스 기획: [`CONCEPT.md`](CONCEPT.md)
- 기능 명세 및 아키텍처: [`SPEC.md`](SPEC.md)

## 프로젝트 구조

| 경로 | 설명 |
| :--- | :--- |
| `Packages/WhyNodeCore` | UI와 분리된 핵심 로직 패키지입니다. 노드 모델, `.whynode` 저장 및 마이그레이션, 무결성 복구, AI 맥락 조립, 응답 검증, 답변 서식, 프로바이더 연결, 힘 기반 배치 시뮬레이션을 담당합니다. |
| `App` | SwiftUI 기반 멀티플랫폼 문서 앱(`DocumentGroup`)입니다. |
| `project.yml` | XcodeGen 프로젝트 정의 파일입니다. `WhyNode.xcodeproj`는 이 파일에서 생성되므로 Git 커밋에서 제외합니다. |

## 사전 준비: AI 연결

WhyNode는 API 키 또는 **내 CLI**로 AI에 연결합니다. 내 CLI는 이 Mac에 로그인된 공식 CLI의 구독을 그대로 사용합니다(macOS 전용). CLI를 설치하고 새 터미널 창에서 한 번 실행해 로그인한 뒤, 설정(⌘,)에서 **다시 확인**을 누르면 됩니다.

| 회사 | CLI | 설치 | 로그인 |
| :--- | :--- | :--- | :--- |
| Anthropic Claude | Claude Code(`claude`) | `curl -fsSL https://claude.ai/install.sh \| bash` (또는 `brew install --cask claude-code`) | `claude` 실행 |
| Google Gemini | Antigravity CLI(`agy`) | `curl -fsSL https://antigravity.google/cli/install.sh \| bash` | `agy` 실행 |

앱은 `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`, `~/bin`과 로그인 셸의 `PATH`에서 CLI를 찾습니다. Codex CLI는 아직 지원하지 않으므로 OpenAI는 API 키로 연결해 주세요.

## AI 연결 및 토큰 절감

WhyNode는 요청마다 해당 노드에 필요한 맥락만 트리에서 골라 보냅니다(`SPEC.md` 6.1 참고). 이 맥락 자체는 매우 가볍기 때문에, CLI가 기본으로 붙이는 시스템 프롬프트나 도구 선언, 전역 규칙이 그대로 실리면 토큰 사용량이 불필요하게 커집니다. 아래 설정은 이러한 오버헤드를 제거하기 위한 구성입니다.

| 연결 방식 | 설정 | 역할 | 실측 효과 |
| :--- | :--- | :--- | :--- |
| **claude CLI** (요청마다 실행) | `--system-prompt` 교체, `--tools ""`, `--strict-mcp-config`, `--setting-sources ""`, `--disable-slash-commands`, `--no-session-persistence` | Claude Code의 기본 지시문, 도구, 사용자 설정, MCP 서버를 요청에서 제외합니다. | 약 18.5k → 1.1k 토큰 |
| | `DISABLE_PROMPT_CACHING=1` | 1시간 프롬프트 캐시 쓰기를 비활성화합니다. 노드 요청마다 맥락이 달라 캐시 적중률이 낮은 반면, 캐시 쓰기는 입력 단가가 2배로 청구됩니다. | 비용 약 25% 절감 |
| **agy** (상시 연결 `agy acp`) | `--agent whynode` | 도구가 없는 전용 에이전트를 사용합니다. 에이전트 본문이 시스템 프롬프트 역할을 하므로 기본 코딩 에이전트의 지시문과 도구 선언이 빠집니다. | 약 11.7k → 2.85k 토큰 |
| | `--gemini-dir <빈 임시 폴더>` | `~/.gemini`의 전역 규칙, 스킬, 플러그인, MCP를 불러오지 않으며, WhyNode 세션 기록도 남기지 않습니다. 로그인은 Keychain을 통해 정상 동작합니다. | |
| | 요청마다 새 세션 생성 | 대화 이력이 누적되어 토큰이 늘어나거나, 다른 가지의 맥락이 섞이고 동시 요청이 직렬화되는 문제를 방지합니다. | |
| **API 키** (Gemini · Claude · OpenAI) | 별도 설정 없음 | WhyNode 시스템 프롬프트와 조립된 맥락만 전송합니다. | |

- 전용 에이전트 파일(`<임시 폴더>/WhyNodeCLI/.agents/agents/whynode.md`)은 `agy`에 연결할 때마다 최신 시스템 프롬프트로 자동 생성되므로 직접 수정할 필요가 없습니다.
- `claude`의 `--bare` 옵션은 구독 로그인 정보를 읽지 못해 사용하지 않습니다.
- 앱은 구독 로그인 토큰을 직접 읽거나 재사용하지 않으며(`SPEC.md` 5.2), 모든 인증은 공식 CLI에 위임합니다.

## 빌드 및 실행 (macOS)

```zsh
# (선택) Xcode가 여러 개 설치된 경우 시스템 기본 설정을 바꾸지 않고 버전 지정
# export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 코어 단위 테스트
(cd Packages/WhyNodeCore && swift test)

# macOS 앱 빌드 및 실행
xcodegen generate
xcodebuild -project WhyNode.xcodeproj -scheme WhyNode -destination 'platform=macOS' -derivedDataPath DerivedData build
open WhyNode.app
```

리포지토리 루트의 `WhyNode.app`은 최신 빌드 결과(`DerivedData/Build/Products/Debug/WhyNode.app`)를 가리키는 로컬 바로가기이며, Git에는 포함하지 않습니다.
