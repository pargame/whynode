# WhyNode

질문과 AI 답변이 짝을 이룬 노드로 지식 마인드맵을 넓혀 가는 macOS · iPadOS 앱입니다. 기획은 `CONCEPT.md`, 명세는 `SPEC.md`, 현재 진행 상황과 다음 할 일은 `STATUS.md`를 봅니다.

## 구조

| 경로 | 내용 |
| :--- | :--- |
| `Packages/WhyNodeCore` | 노드 모델 · `.whynode` 직렬화 · 무결성 복구 · v1 가져오기 · AI 맥락 패키지 · 응답 검증 · 답변 서식 · 프로바이더(API · CLI · agy 상시 연결) · 시뮬레이션 배치 |
| `App` | SwiftUI 문서 앱 (`DocumentGroup`) |
| `project.yml` | XcodeGen 프로젝트 정의. `WhyNode.xcodeproj`는 생성물이라 커밋하지 않습니다. |

## AI 연결과 토큰 절감

WhyNode는 요청마다 트리에서 그 노드에 필요한 맥락만 골라 새로 보냅니다(SPEC 6.1). 그래서 CLI가 스스로 붙이는 기본 지시문 · 도구 정의 · 사용자 규칙이 WhyNode 내용보다 훨씬 커지기 쉽고, 아래 설정이 그것을 막습니다. 인자나 설정을 바꿀 때는 실측 테스트(`STATUS.md` 확인 방법)로 토큰을 다시 재 봅니다.

| 연결 | 설정 | 이유 | 실측 |
| :--- | :--- | :--- | :--- |
| claude CLI (1회 실행) | `--system-prompt`로 기본 지시문 교체, `--tools ""` · `--strict-mcp-config` · `--setting-sources ""` · `--disable-slash-commands` · `--no-session-persistence` | Claude Code 기본 지시문 · 도구 · 사용자 설정 · MCP를 싣지 않는다 | 약 18.5k → 1.1k |
| | `DISABLE_PROMPT_CACHING=1` | 요청 내용이 매번 달라 캐시를 다시 읽지 않는데, 기본 1시간 캐시 쓰기는 입력 단가가 2배다 | 비용 약 25% 절감 |
| agy (상시 연결 `agy acp`) | `--agent whynode` | 도구가 없는 전용 에이전트. 본문이 시스템 프롬프트가 되어 기본 코딩 에이전트의 지시문 · 도구 선언을 대신한다. ACP의 `systemPrompt`는 append만 되어 교체할 수 없다 | 약 11.7k → 2.85k (둘 합산) |
| | `--gemini-dir <빈 임시 폴더>` | 사용자 `~/.gemini`의 전역 규칙 · 스킬 · 플러그인 · MCP를 싣지 않고, WhyNode 세션 기록도 거기 남기지 않는다. 로그인은 Keychain에서 읽어 영향이 없다 | |
| | 요청마다 새 세션 | 세션을 재사용하면 대화 기록이 쌓여 토큰이 늘고, 다른 가지 맥락이 섞이며, 동시 요청이 줄을 선다 | |
| API 키 (Gemini · Claude · OpenAI) | 없음 | WhyNode 지시문과 맥락만 보내므로 덜어낼 기본 몫이 없다 | |

* 전용 에이전트 파일(`<임시 폴더>/WhyNodeCLI/.agents/agents/whynode.md`)은 앱이 agy에 연결할 때마다 현재 시스템 프롬프트로 새로 씁니다. 직접 고치지 않습니다.
* `--bare`(claude 최소 모드)는 구독 로그인을 읽지 않아 쓰지 않습니다.
* 사용자 구독 로그인 토큰을 앱이 직접 읽거나 재사용하지 않습니다(SPEC 5.2). CLI가 가진 로그인을 그대로 씁니다.

## 빌드

시스템 기본 Xcode 설정을 바꾸지 않고, 명령마다 `DEVELOPER_DIR`로 Xcode를 지정합니다.

```zsh
export DEVELOPER_DIR=/Applications/Xcode-26.1.1.app/Contents/Developer

# 코어 테스트
(cd Packages/WhyNodeCore && swift test)

# Mac 앱
xcodegen generate
xcodebuild -project WhyNode.xcodeproj -scheme WhyNode -destination 'platform=macOS' -derivedDataPath DerivedData build
open WhyNode.app
```

`WhyNode.app`은 빌드 결과(`DerivedData/Build/Products/Debug/WhyNode.app`)를 가리키는 바로가기입니다. 빌드할 때마다 최신 앱을 가리키며, 커밋하지 않습니다.
