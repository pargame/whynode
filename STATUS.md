# WhyNode 진행 현황

새 세션은 이 문서부터 읽습니다. 기획은 `CONCEPT.md`, 명세는 `SPEC.md`, 빌드 방법은 `README.md`에 있습니다.

## 핵심 구조

```text
App (SwiftUI 문서 앱)
├ WhyNodeApp        시작 화면 창 + DocumentGroup + 보기 메뉴(글자 크기)
├ LauncherView      새 프로젝트 · 열기, 저장 위치 프로젝트 카드 격자(ProjectEntry · ProjectCard, 휴지통으로 이동)
├ MapScreen         캔버스 · 추가 질문 칩 · 메뉴 · 제스처 · 시뮬레이션 제어
├ CanvasModel       카메라 · 끌기 · 핀치 · 시뮬레이션 상태, 노드 층 · 선 층
├ CanvasParts       애니메이션되는 선 · 프레임 타이머 · 트랙패드 스크롤 이동 · ⌫ 삭제 키 (macOS)
├ NodeBubble        노드 (원 → 포커스 시 아래로 넓어지는 카드). 본문(NodeBubbleBody)은 화면 배율을 모르는 Equatable 하위 뷰라 확대 · 축소 중에는 테두리 · 빛만 다시 그림
├ AnswerView        답변 서식 블록 그리기
├ AIController      요청 → 검증 → 문서 반영, 동시 요청 한도
├ WhyNodeDocument   파일 읽기/쓰기 · 실행 취소 · 진행 중 요청(inFlight)
├ SettingsStore     AI 설정 · 물리 조절값 · 글자 크기 · 저장 위치, 프로바이더 생성, agy 공유 연결
├ ProjectFiles      새 프로젝트 선저장 · 새 프로젝트 메뉴 (macOS)
├ AISetupView       첫 실행 안내 · 설정 화면
├ PhysicsControl    시뮬레이션 버튼 · 조절값 패널
├ Theme             라이트 · 다크 의미 색, 글자 크기 반영 글꼴(Font.scaled)
└ SnapshotRenderer  디버그용 화면 PNG 렌더

WhyNodeCore (화면 없는 로직, 단위 테스트 대상)
├ Model / Codec     .whynode 구조 · 저장 형식 · v2→v3 이전 (SPEC 7), 시작 화면용 요약(ProjectPreview)
├ MindMap           노드 생성 · 상태 전환 · 편집 규칙 (SPEC 2~3)
├ Integrity         열 때 무결성 복구 (SPEC 7.5)
├ Layout            새 노드 초기 자리 (부채꼴)
├ Physics           시뮬레이션 · 조절값 (SPEC 2.6)
├ Context           AI 맥락 패키지 (SPEC 6.1)
├ Validation        응답 검증 · 중복 제거 (SPEC 6.4)
├ Prompt / ResponseParsing  시스템 프롬프트(v3, 영어 지시문 · 답변은 질문 언어) · JSON 추출
├ AnswerFormat      답변 서식 블록 · 인라인 해석 (SPEC 6.5)
├ AIConfig          회사 · 연결 방식 · 오류 · 연결 테스트
├ Provider          AIProvider 인터페이스 · capabilities
├ HTTPProviders     ① Gemini · Claude · OpenAI API
├ CLIProvider       ③ claude 1회 실행 호출 · CLI 찾기(캐시) · 모델 목록 (macOS)
└ ACPClient         ③ agy 상시 연결 (agy acp, 전용 에이전트 · 빈 설정 폴더, 요청 취소, macOS)
```

* **데이터 흐름**: 화면 동작 → `WhyNodeDocument.perform`(UndoManager 등록 = 자동 저장 트리거) → `MindMap` 변경. AI가 필요하면 `AIController`가 `ContextBuilder`로 맥락을 만들어 프로바이더에 보내고, `ResponseValidator`를 거쳐 `MindMap.applyAnswer`로 반영합니다.
* **시뮬레이션 조절값**: 기본 1 / 2 / 50 / 1(반발력 / 장력 / 링크 거리 / 중심력, 주인이 맞춘 값), 범위는 기본값이 가운데 오도록 0~기본값×2(0~2 / 0~4 / 0~100 / 0~2). 장력 실측: 3까지 안정, 4는 끝까지 미세 진동, 6은 발산. 링크 거리는 원 가장자리 사이 길이라 목표 중심 거리는 `링크 거리 + 2 × 반지름(70)`이고, 충돌 여백은 원마다 4pt입니다. 실측(반발력 5일 때): 링크 0 / 40 / 80에서 보이는 선 길이 약 30 / 62 / 96pt.
* **시뮬레이션**: 버튼을 누르면 `MapScreen`이 `ForceSimulation`을 만들고 `FrameTicker`로 매 프레임 한 틱씩 돌려 화면에만 반영하다가, 멈추는 순간 `MindMap.arrange`로 Undo 1회 반영합니다.
* **화면 갱신 범위**: 카메라 · 노드 끌기 · 시뮬레이션처럼 매 프레임 바뀌는 값은 `CanvasModel`(@Observable)에 두고 `NodeLayer` · `EdgeLayer`만 읽습니다. `MapScreen.body`에서 이 값을 읽으면 매 프레임 화면 전체가 다시 계산되므로 피합니다(`isRunning`은 그래서 계산 프로퍼티가 아닌 저장 프로퍼티). 선은 시뮬레이션 중에만 `Canvas` 하나로 그리고, 평소에는 노드 애니메이션과 박자를 맞추는 `EdgeShape`를 씁니다.
* **글자 크기**: 앱 전체 배율 `SettingsStore.textScale`(0.8~1.8, 0.1 단위) × 노드별 `Node.textScale`(0.6~2.5, 파일 저장, schemaVersion 3)을 노드 질문 · 답변 · 추가 질문 칩 글꼴에만 곱합니다(`Font.scaled`). 노드별 값은 펼친 노드 위 핀치로 바꾸고(핀치 중 값은 `CanvasModel.textPinch`), 놓을 때 Undo 1회로 확정합니다. ⌘0은 포커스 노드 글자 크기가 바뀌어 있으면 그 노드를(`FocusedValues.resetFocusedNodeTextScale`), 아니면 앱 전체 배율을 되돌립니다. 노드 크기(원 140 · 카드 폭 380)는 고정이고, 원 안 질문 줄 수가 `4 / 배율`로 줄어 생략(…)이 늘어납니다. 도구 막대 버튼과 보기 메뉴 ⌘= · ⌘- · ⌘0.
* **새 노드 자동 정리**: `MapScreen.arrange(around:)`가 `ForceSimulation(movable:alpha: 0.6)`으로 새 노드 · 형제 · 형제의 자식만 움직이는 부분 계산을 돌립니다(`CanvasModel.isSimulating`은 true, 버튼 상태인 `isRunning`은 false). 끝나면 `WhyNodeDocument.applyWithoutUndo`로 `applyLayout`(고정 노드 제외)을 반영하고, 창의 `NSDocument.updateChangeCount`로 변경 표시만 합니다(`WindowReader` → `CanvasModel.window`). 정리 중 노드 수가 줄면(⌘Z · 삭제) 결과 없이 멈춥니다. 선은 버튼 시뮬레이션에서만 `Canvas`로 그려 자동 정리 중 흐림 · 빛이 유지됩니다. 버튼 시뮬레이션 중이면 새 노드가 그 계산에 합류합니다.
* **호버 빛**: `CanvasModel.hoveredId`는 애니메이션 없이 바꾸고, `NodeBubble.isHighlighted`(테두리 안쪽 번짐) · `EdgeItem.highlighted`(선 번짐)를 조건부 뷰 + `.transition(.opacity)` + `.animation(Theme.glowAnimation, value:)`로 빛에만 애니메이션을 겁니다. 빛 뷰는 강조될 때만 만들어 흐림(blur) 비용을 그 노드 · 선에만 씁니다.
* **실행 취소와 AI 요청**: AI 답변도 Undo 단계입니다. 되돌린 결과에 진행 중 요청(`WhyNodeDocument.inFlight`)이 없는 대기 노드가 생기면 `interruptPending`으로 "중단됨" 오류 상태로 바꿔 다시 시도할 수 있게 합니다.
* **새 프로젝트 선저장**: `ProjectCreator`가 항상 `ProjectFiles.create`로 저장 위치(`SettingsStore.projectFolder`, 기본 `~/Documents/WhyNode`, 설정에서 변경 · `project.folder`)에 `새 프로젝트.whynode`를 먼저 쓴 뒤 `openDocument(at:)`로 엽니다(이름 없는 문서 경로 없음). 시작 화면 · 파일 > 새 프로젝트(⌘N, `NewProjectCommands`)가 같은 경로를 씁니다. macOS 전용. 루트 주제 입력 · 수정 시 `ProjectFiles.renameToTopic`이 자동 이름(`새 프로젝트`, 이전 주제, 뒤 번호 포함)일 때만 `NSDocument.move(to:)`로 파일 이름을 주제로 바꿉니다.
* **화면 언어**: 원문은 영어 키(코드 리터럴), 번역은 `App/ko.lproj/Localizable.strings` · `Packages/WhyNodeCore/Sources/WhyNodeCore/Resources/ko.lproj/Localizable.strings`(코어는 `L(...)` = `String(localized:bundle: .module)`). 실행 취소 이름은 `WhyNodeDocument.perform(_: LocalizedStringResource)`. `SettingsStore.language`(기본 English, `app.language`)를 시작할 때 앱 도메인 `AppleLanguages`에 넣어 적용하고, 바꾸면 `relaunch()`로 다시 켭니다. 새 문구를 넣으면 ko 문자열 파일에도 같은 키(보간은 `%@` · `%lld`)를 추가합니다. 버튼 문구에는 말줄임표(…)를 쓰지 않습니다.
* **설정 저장**: 회사 · 연결 방식 · 모델 · 물리 조절값 · 글자 크기 · 저장 위치 · 언어는 UserDefaults(`ai.settings`, `physics.settings`, `text.scale`, `project.folder`, `app.language`), API 키는 Keychain(`com.pargame.whynode.apikey`).
* **AI 호출 방식(현재)**: agy는 앱 실행 동안 `agy acp --agent whynode --gemini-dir <임시 빈 폴더>`를 하나 띄워 두고(시작 화면에서 미리 연결), 노드 요청마다 새 세션을 열고 닫습니다. 전용 에이전트 파일(`<임시 폴더>/WhyNodeCLI/.agents/agents/whynode.md`, 도구 없음, 본문 = 시스템 프롬프트)은 연결할 때마다 새로 씁니다. claude는 시작 비용이 작아 요청마다 `claude -p`를 1회 실행합니다. 공유 연결은 `SettingsStore`가 소유합니다.

## 확인 방법

| 대상 | 방법 |
| :--- | :--- |
| 코어 로직 | `cd Packages/WhyNodeCore && swift test` (57개) |
| 실제 CLI 연결 | `WHYNODE_LIVE_CLI=claude swift test --filter 실제_CLI` (실제 사용량 발생) |
| 답변 서식 실측 | `WHYNODE_LIVE_ANSWER=claude` 또는 `agy swift test --filter 실제_답변_서식` (실제 답변과 블록 해석 결과 출력) |
| agy 상시 연결 | `WHYNODE_LIVE_ACP=1 [WHYNODE_LIVE_ACP_MODEL=모델] swift test --filter 상시_연결` (2회 연속 요청 시간 · 토큰 사용량 출력) |
| 화면 모양 | 디버그 빌드 실행 파일에 `--render-snapshots <폴더>`(언어는 `defaults write com.pargame.whynode app.language ko|en`) → 라이트 · 다크 PNG 생성 후 확인 (창을 띄우지 않음). `nodes-large-*`는 글자 1.5배, 맨 오른쪽 노드는 호버 빛, `cards-*`는 시작 화면 프로젝트 카드 |
| 앱 실행 | `open WhyNode.app` (빌드 결과 바로가기). 이미 켜져 있으면 ⌘Q 후 다시 열어야 새 빌드가 뜸 |

모든 빌드 명령에는 `DEVELOPER_DIR=/Applications/Xcode-26.1.1.app/Contents/Developer`를 붙입니다. 이 Xcode는 다른 작업(언리얼)과 공유하므로 `xcode-select`는 바꾸지 않습니다.

## 측정 기록

표의 위 다섯 줄은 프롬프트 v2(한국어 지시문) 때 연결 테스트(suggest 요청) 기준입니다. 아래 표는 루트 답변(answer) 요청을 같은 주제로 한국어 · 영어로 보낸 실측입니다(2026-11-24, `WHYNODE_LIVE_TOKENS=claude|agy swift test --filter 실제_언어별_토큰`).

| 항목 | 값 |
| :--- | :--- |
| claude CLI 호출 1회 (경량 인자) | 약 1.1k 토큰, 4초 안팎 (수정 전 약 18.5k 토큰) |
| claude CLI 캐시 끄기 (`DISABLE_PROMPT_CACHING=1`) | 입력 약 1.1k가 1시간 캐시 쓰기(2배 단가) 대신 일반 입력으로 처리, 같은 요청 비용 약 25% 절감 |
| agy 상시 연결 (기본 모델 `gemini-4-neon-high`) | 연결 0.3~3초(최초 1회), 요청 12~18초. 입력 토큰: 격리 전 약 11.2k~12.2k → 전용 에이전트 + 빈 설정 폴더 약 2.85k(WhyNode 시스템 프롬프트 포함) |
| agy 상시 연결 `gemini-3.8-flash-low` | 요청 4~6초 (1회 실행 방식에서는 즉시 실패하던 모델) |
| agy 상시 연결 `gemini-4-neon-low` | 요청 7~13초 |

| 루트 답변 요청 (주제: 양자역학 / quantum mechanics) | 입력 | 출력 | 비용 · 답변 언어 |
| :--- | :--- | :--- | :--- |
| claude 기본 모델, 프롬프트 v2 한국어 주제 | 2,611 | 716 | $0.0248 · 한국어 |
| claude 기본 모델, 프롬프트 v2 영어 주제 | 2,617 | 723 | $0.0249 · **한국어**(언어 고정 문제) |
| claude 기본 모델, 프롬프트 v3 한국어 주제 | 2,269 | 622 | $0.0215 · 한국어 |
| claude 기본 모델, 프롬프트 v3 영어 주제 | 2,275 | 512 | $0.0193 · 영어 |
| agy 기본 모델, 프롬프트 v3 한국어 주제 | 2,874 | 2,683 (생각 2,380 포함) | 한국어 |
| agy 기본 모델, 프롬프트 v3 영어 주제 | 2,868 | 1,989 (생각 1,725 포함) | 영어 |

* v3(영어 지시문)은 v2보다 입력이 약 13% 적고, 주제 언어에 따라 입력 차이는 거의 없습니다(6토큰). 출력은 영어 답변이 한국어보다 적게 나옵니다. agy 출력의 대부분은 모델의 생각 토큰이라 회차마다 크게 달라집니다.

## 다음 할 일

1. **앱 화면 실사용 확인**: 시작 화면 프로젝트 카드(저장 위치 바꾸면 목록이 바뀌는지), 도구 막대 `프로젝트` 버튼으로 돌아가기. 설정에서 언어 바꾸고 다시 켜기, 메뉴 · 시스템 창 언어. 새 프로젝트가 ~/Documents/WhyNode에 바로 만들어지고 끌 때 묻지 않는지, ⌘N도 같은지, 저장 위치 변경, 도구 막대 AI 설정 시트의 닫기 버튼, 주제 입력 시 파일 이름이 주제로 바뀌는지. 자동 정리 뒤 앱을 바로 닫았다 열어도 새 노드 위치가 저장되는지(`updateChangeCount` 경로). 펼친 노드 위 핀치가 화면 확대 대신 글자 크기만 바꾸는지, ⌘0 · 컨텍스트 메뉴 되돌리기, 추가 질문 연달아 고르기(포커스 유지), 맨 아래 줄 `직접 질문…` · `다른 질문 3개` 반반 칩, 노드 호버 빛, 새 노드 생성 시 주변 자동 정리(겹침 해소 · 펼친 카드와는 원 크기로만 충돌), ⌫ 삭제(입력창에서는 글자만 지워지는지), 확대 · 축소 시 테두리 굵기 고정. agy 격리 연결 · claude 캐시 끄기 적용 후 앱에서 실제로 답변 · 추가 질문이 잘 오는지. 화면 갱신 구조 변경(`CanvasModel`) 후 시뮬레이션 · 화면 이동 · 노드 끌기 · 포커스 애니메이션이 예전처럼 움직이는지.
2. **디자인 전면 개편(예정)**: 주인이 나중에 한 번에 갈아엎을 예정. 그 전까지는 기능 · 가독성 위주로만 손댄다. 화면 움직임은 스냅샷으로 확인할 수 없어 실제 사용 피드백으로 다듬는다.
3. **시뮬레이션 손맛**: 기본 조절값 · 패널 펼침 방식은 실제 사용 피드백으로 다듬는다. 반발력은 모든 쌍 계산이라 노드가 수백 개를 넘으면 Barnes-Hut로 바꾼다(SPEC 8.4).
4. **미구현 명세** (SPEC은 목표 설계, 아래는 아직 코드에 없음)
   * 가지 묶음(SPEC 2.5, 8.3). 수동 `가지 접기`는 `collapsed` 저장과 "접힘" 표시만 하고 하위 노드를 숨기지 않는다.
   * 성능 설계(SPEC 8: `Canvas` 엔진 · 화면 밖 생략 · LOD · 근사 · 백그라운드 계산 · 맥락 조립 · 검증), 자동 배치 좌표를 Undo 없이 변경 표시만 하는 방법(SPEC 7.6 미결, 지금은 이어지는 답변 반영 때 함께 저장).
   * ② 공식 로그인(SPEC 5.1): 각 회사에 앱 등록이 필요해 설정 화면에 "준비 중"으로만 둔다.
5. **agy 세션 열기 시간 초과 없음**: 질문 요청(`session/prompt`)은 시간 초과로 끊기지만, 연결 · 세션 열기(`start`, `session/new`, `session/set_model`)에서 agy가 멈추면 여전히 무한 대기한다.
6. **미검증**: API 키 연결 3종(키가 없어 실제 호출 미확인), iPad 빌드(Xcode에 iOS 플랫폼 미설치), codex CLI(미설치로 미지원).
