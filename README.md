# WhyNode

질문과 AI 답변이 짝을 이룬 노드로 지식 마인드맵을 넓혀 가는 macOS · iPadOS 앱입니다. 기획은 `CONCEPT.md`, 명세는 `SPEC.md`를 봅니다.

## 구조

| 경로 | 내용 |
| :--- | :--- |
| `Packages/WhyNodeCore` | 노드 모델 · `.whynode` 직렬화 · 무결성 복구 · v1 가져오기 · AI 맥락 패키지 · 응답 검증 · 프로바이더 인터페이스 |
| `App` | SwiftUI 문서 앱 (`DocumentGroup`) |
| `project.yml` | XcodeGen 프로젝트 정의. `WhyNode.xcodeproj`는 생성물이라 커밋하지 않습니다. |

## 빌드

시스템 기본 Xcode 설정을 바꾸지 않고, 명령마다 `DEVELOPER_DIR`로 Xcode를 지정합니다.

```zsh
export DEVELOPER_DIR=/Applications/Xcode-26.1.1.app/Contents/Developer

# 코어 테스트
(cd Packages/WhyNodeCore && swift test)

# Mac 앱
xcodegen generate
xcodebuild -project WhyNode.xcodeproj -scheme WhyNode -destination 'platform=macOS' -derivedDataPath DerivedData build
open DerivedData/Build/Products/Debug/WhyNode.app
```
