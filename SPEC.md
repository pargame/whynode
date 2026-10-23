# WhyNode 기능 명세서 및 기술 아키텍처 (SPEC)

> **문서 버전**: v1.1.0  
> **프로젝트**: WhyNode (와이노드)  
> **타깃 플랫폼**: iPadOS, macOS (SwiftUI 멀티플랫폼 네이티브)  

---

## 1. 인터랙션 및 상태 머신 (State Machine)

### 1.1 노드 생명주기
1. **후보 상태 (Candidate Node)**:
   - 부모 노드 주변에 플로팅 형태로 배치.
   - 포커스 디밍 활성화 (기존 노드/배경 `opacity: 0.3`, 후보 노드는 `opacity: 1.0` 강조).
2. **컴팩트 상태 (Compact Node)**:
   - 사용자가 후보 노드 클릭 시 확정.
   - 미선택된 다른 후보 노드들은 즉시 소멸(Pruning).
   - 질문 텍스트만 표시.
3. **확장 상태 (Expanded Node)**:
   - 컴팩트 노드 탭 시 아코디언 형태로 상하 확장.
   - 질문에 대한 AI의 3~4줄 핵심 개념/해설 표시.

---

## 2. 기술 아키텍처 및 툴체인

* **UI 프레임워크**: Apple SwiftUI (Multiplatform: macOS + iPadOS)
* **그래프 렌더링**: SwiftUI `Canvas` 및 `GeometryReader` 커스텀 무한 캔버스 엔진
* **자동 배치 엔진**: 힘-기반(Force-directed) 충돌 회피 알고리즘
* **인증 모델**: Google OAuth2 (PKCE 방식) & Google AI Studio 무료 티어 API Key
* **로컬 파일 영속성**: Swift `Codable` 기반 JSON 파일 저장 (`.whynode`)
