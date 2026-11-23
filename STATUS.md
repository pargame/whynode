# WhyNode 진행 현황

새 세션은 이 문서부터 읽습니다. 기획은 `CONCEPT.md`, 명세는 `SPEC.md`, 빌드 방법은 `README.md`에 있습니다.

## 핵심 구조

```text
App (SwiftUI 문서 앱)                       WhyNodeCore (화면 없는 로직, 단위 테스트 대상)
├ WhyNodeApp      시작 화면 창 + DocumentGroup   ├ Model / Codec     .whynode 구조 · 저장 형식 (SPEC 7)
├ LauncherView    새 프로젝트 · 열기 · 최근 · v1   ├ MindMap           노드 생성 · 상태 전환 · 편집 규칙 (SPEC 2~3)
├ MapScreen       캔버스 · 추가 질문 칩 · 메뉴      ├ Integrity         열 때 무결성 복구 (SPEC 7.5)
├ NodeBubble      원형 노드 표시                  ├ V1Import          v1 파일 변환 (SPEC 7.7)
├ AIController    요청 → 검증 → 문서 반영          ├ Context           AI 맥락 패키지 (SPEC 6.1)
├ SettingsStore   AI 설정 저장 · 프로바이더 생성   ├ Validation        응답 검증 · 중복 제거 (SPEC 6.4)
├ AISetupView     첫 실행 안내 · 설정 화면         ├ Prompt / ResponseParsing  시스템 프롬프트 · JSON 추출
├ WhyNodeDocument 파일 읽기/쓰기 · 실행 취소       ├ AIConfig          회사 · 연결 방식 · 오류 · 연결 테스트
├ Theme           라이트 · 다크 의미 색           ├ CLIProvider       ③ agy · claude 호출 (macOS)
└ SnapshotRenderer 디버그용 화면 PNG 렌더          └ HTTPProviders     ① Gemini · Claude · OpenAI API
```

* **데이터 흐름**: 화면 동작 → `WhyNodeDocument.perform`(UndoManager 등록 = 자동 저장 트리거) → `MindMap` 변경. AI가 필요하면 `AIController`가 `ContextBuilder`로 맥락을 만들어 프로바이더에 보내고, `ResponseValidator`를 거쳐 `MindMap.applyAnswer`로 반영합니다.
* **설정 저장**: 회사 · 연결 방식 · 모델은 UserDefaults(`ai.settings`), API 키는 Keychain(`com.pargame.whynode.apikey`).
* **AI 호출 방식(현재)**: 요청마다 CLI를 1회 실행하고 종료합니다(`agy -p …`, `claude -p …`). 상시 연결(`agy acp`)은 아직 아닙니다.

## 확인 방법

| 대상 | 방법 |
| :--- | :--- |
| 코어 로직 | `cd Packages/WhyNodeCore && swift test` (32개) |
| 실제 CLI 연결 | `WHYNODE_LIVE_CLI=agy swift test --filter 실제_CLI` (`claude`도 가능, 실제 사용량 발생) |
| 화면 모양 | 디버그 빌드 실행 파일에 `--render-snapshots <폴더>` → 라이트 · 다크 PNG 생성 후 확인 (창을 띄우지 않음) |
| 앱 실행 | `open WhyNode.app` (빌드 결과 바로가기). 이미 켜져 있으면 ⌘Q 후 다시 열어야 새 빌드가 뜸 |

모든 빌드 명령에는 `DEVELOPER_DIR=/Applications/Xcode-26.1.1.app/Contents/Developer`를 붙입니다. 이 Xcode는 다른 작업(언리얼)과 공유하므로 `xcode-select`는 바꾸지 않습니다.

## 측정 기록

| 항목 | 값 |
| :--- | :--- |
| claude CLI 호출 1회 (경량 인자) | 약 1.1k 토큰, 4초 안팎 (수정 전 약 18.5k 토큰) |
| agy CLI 호출 1회 (경량 인자, 기본 모델) | 약 2.7k 토큰 + 캐시 읽기 약 9.9k, 약 17초 (수정 전 13~16k 토큰) |
| agy `--model gemini-3.8-flash-low` | 즉시 실패, 원인 미확인 |

## 다음 할 일

1. **agy 지연 원인 측정**: 17초 중 프로세스 시작 · 초기화와 모델 응답 시간을 나눠 잰다. 시작 시간이 크면 앱 실행 동안 `agy acp`(claude는 `--input-format stream-json`)를 상시 연결하고, 노드 요청마다 새 세션을 연다(대화 누적으로 토큰이 늘지 않게).
2. **주인 결정 대기**: 펼친 노드를 원형으로 유지할지, 펼칠 때만 둥근 카드로 바꿀지(CONCEPT ③ 변경 여부).
3. **미구현 명세**: 가지 묶음(SPEC 2.5, 8.3), 성능 설계(SPEC 8: 화면 밖 생략 · LOD · 힘 기반 부분 배치), 자동 배치 좌표의 Undo 없는 저장 방법 검증(SPEC 7.6 미결).
4. **미검증**: API 키 연결 3종(키가 없어 실제 호출 미확인), iPad 빌드(Xcode에 iOS 플랫폼 미설치), ② 공식 로그인(각 회사 앱 등록 필요), codex CLI(미설치로 미지원).
