# WhyNode

질문 하나와 AI 답변 하나를 노드로 묶어, 꼬리에 꼬리를 무는 질문으로 지식 마인드맵을 키워 가는 macOS · iPadOS 앱이다.

- 기획: `CONCEPT.md`
- 명세: `SPEC.md`
- 진행 현황과 다음 할 일: `STATUS.md`

## 구조

| 경로 | 내용 |
| :--- | :--- |
| `Packages/WhyNodeCore` | 화면이 없는 로직. 노드 모델, `.whynode` 저장 형식, 무결성 복구, AI 맥락 조립, 응답 검증, 답변 서식, 프로바이더 연결, 시뮬레이션 |
| `App` | SwiftUI 문서 앱(`DocumentGroup`) |
| `project.yml` | XcodeGen 프로젝트 정의. `WhyNode.xcodeproj`는 여기서 생성하므로 커밋에서 뺀다. |

## AI 연결과 토큰 절감

요청마다 그 노드에 필요한 맥락만 트리에서 골라 보낸다(SPEC 6.1). 이 맥락은 작아서, CLI가 기본으로 덧붙이는 지시문 · 도구 정의 · 사용자 규칙이 오히려 더 커지기 쉽다. 아래 설정은 그 덧붙임을 걷어 내기 위한 것이다. 인자를 바꿨다면 `STATUS.md`의 실측 테스트로 토큰을 다시 잰다.

| 연결 | 설정 | 하는 일 | 실측 |
| :--- | :--- | :--- | :--- |
| claude CLI (요청마다 실행) | `--system-prompt`로 기본 지시문 교체, `--tools ""`, `--strict-mcp-config`, `--setting-sources ""`, `--disable-slash-commands`, `--no-session-persistence` | Claude Code의 기본 지시문, 도구, 사용자 설정, MCP를 싣지 않는다. | 약 18.5k → 1.1k |
| | `DISABLE_PROMPT_CACHING=1` | 1시간 캐시 쓰기를 끈다. 요청 내용이 매번 달라 캐시를 다시 읽을 일이 없는데, 캐시 쓰기는 입력 단가가 두 배다. | 비용 약 25% 절감 |
| agy (상시 연결 `agy acp`) | `--agent whynode` | 도구가 없는 전용 에이전트를 쓴다. 에이전트 본문이 곧 시스템 프롬프트라 기본 코딩 에이전트의 지시문과 도구 선언이 빠진다. ACP의 `systemPrompt`는 덧붙이기만 되고 바꿀 수는 없어서 이 방법을 택했다. | 약 11.7k → 2.85k |
| | `--gemini-dir <빈 임시 폴더>` | 사용자 `~/.gemini`의 전역 규칙, 스킬, 플러그인, MCP를 읽지 않는다. WhyNode 세션 기록도 거기에 남기지 않는다. 로그인은 Keychain에서 읽으므로 그대로 된다. | |
| | 요청마다 새 세션 | 대화 기록이 쌓이지 않게 한다. 세션을 이어 쓰면 토큰이 늘고, 다른 가지의 맥락이 섞이고, 동시 요청이 차례를 기다리게 된다. | |
| API 키 (Gemini · Claude · OpenAI) | 없음 | WhyNode 지시문과 맥락만 보낸다. | |

- 전용 에이전트 파일(`<임시 폴더>/WhyNodeCLI/.agents/agents/whynode.md`)은 agy에 연결할 때마다 현재 시스템 프롬프트로 새로 쓴다. 손으로 고칠 파일이 아니다.
- claude의 `--bare`(최소 모드)는 구독 로그인을 읽지 못해서 쓰지 않는다.
- 앱은 구독 로그인 토큰을 직접 읽거나 재사용하지 않는다(SPEC 5.2). 로그인은 CLI가 가진 것을 그대로 쓴다.

## 빌드

시스템 기본 Xcode 설정은 건드리지 않는다. 명령마다 `DEVELOPER_DIR`로 Xcode를 고른다.

```zsh
export DEVELOPER_DIR=/Applications/Xcode-26.1.1.app/Contents/Developer

# 코어 테스트
(cd Packages/WhyNodeCore && swift test)

# Mac 앱
xcodegen generate
xcodebuild -project WhyNode.xcodeproj -scheme WhyNode -destination 'platform=macOS' -derivedDataPath DerivedData build
open WhyNode.app
```

리포 루트의 `WhyNode.app`은 빌드 결과(`DerivedData/Build/Products/Debug/WhyNode.app`)로 가는 바로가기다. 빌드할 때마다 최신 앱을 가리키며, 커밋하지 않는다.
