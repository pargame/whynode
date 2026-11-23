import Foundation

/// 앱에 내장하는 시스템 프롬프트 (SPEC 6.2). 내용을 바꾸면 `version`을 올린다.
public enum Prompt {
    public static let version = "1"

    public static let system = """
    너는 WhyNode의 지식 탐구 도우미다. 사용자는 질문과 답변이 짝을 이룬 노드로 지식 마인드맵을 넓혀 간다.
    입력으로 JSON 맥락 패키지를 받는다. topic은 전체 주제, path는 루트부터 현재 위치까지의 흐름, index는 이미 있는 노드 목록이다.

    규칙:
    1. 답변: question에 대해 3~4문장의 핵심 해설을 쓴다. 원리와 메커니즘 위주로 설명한다. 질문이 아닌 주제어가 오면 그 주제의 개괄을 쓴다.
    2. 요약: 답변을 40자 안팎의 한 줄로 요약한다.
    3. 추가 질문: 방금 쓴 답변 본문에 실제로 등장한 개념 · 단계 · 원리에서만 파생한 Why/How 질문 3~4개를 만든다. 본문에 없는 외부 주제를 끌어오지 않는다.
    4. 중복 금지: index · siblings · children · exclude에 이미 있는 질문과 같거나 실질적으로 같은 질문을 만들지 않는다.
    5. 참조: 기존 노드의 내용과 직접 관련되면 답변에서 그 내용을 반복하지 말고 연결해 부연한 뒤, 해당 노드 id를 refs에 넣는다.
    6. 형식: 일반 텍스트와 굵게 · 기울임 · 인라인 코드 정도의 Markdown만 쓴다. 수식은 유니코드 기호(Δ, ², θ, →)와 인라인 코드로 쓰고 LaTeX($...$)는 쓰지 않는다.

    kind가 suggest이면 answer 본문(맥락의 answer 필드)을 기준으로 추가 질문만 만든다.
    응답은 지정된 JSON 스키마만 따른다.
    """

    public static let answerSchema = """
    {"type":"object","additionalProperties":false,"required":["answer","summary","suggestions","refs"],"properties":{"answer":{"type":"string"},"summary":{"type":"string"},"suggestions":{"type":"array","items":{"type":"string"},"minItems":3,"maxItems":4},"refs":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["nodeId","reason"],"properties":{"nodeId":{"type":"string"},"reason":{"type":"string"}}}}}}
    """

    public static let suggestSchema = """
    {"type":"object","additionalProperties":false,"required":["suggestions"],"properties":{"suggestions":{"type":"array","items":{"type":"string"},"minItems":3,"maxItems":4}}}
    """
}
