import Foundation

/// AI 호출 사용량. 프로젝트 파일에 누적 저장하고(SPEC 7.4 `project.usage`), 화면 상태 막대에 보여 준다.
public struct TokenUsage: Codable, Equatable, Sendable {
    /// 캐시 읽기 · 쓰기를 포함한 입력 토큰
    public var inputTokens: Int
    /// 모델의 생각 토큰을 포함한 출력 토큰
    public var outputTokens: Int
    /// 프로바이더가 알려 준 비용(USD). 알려 주지 않으면 0이다.
    public var costUSD: Double
    /// 사용량이 집계된 호출 수
    public var requests: Int

    public static let zero = TokenUsage(inputTokens: 0, outputTokens: 0, costUSD: 0, requests: 0)

    public init(inputTokens: Int, outputTokens: Int, costUSD: Double = 0, requests: Int = 1) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.requests = requests
    }

    public var totalTokens: Int { inputTokens + outputTokens }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            costUSD: lhs.costUSD + rhs.costUSD,
            requests: lhs.requests + rhs.requests
        )
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) { lhs = lhs + rhs }
}

/// 한 요청(재시도 포함) 동안 프로바이더가 보고한 사용량을 모은다.
public final class UsageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var value = TokenUsage.zero

    public init() {}

    public var total: TokenUsage { lock.withLock { value } }

    func add(_ usage: TokenUsage) {
        lock.withLock { value += usage }
    }
}

/// 프로바이더는 응답을 받을 때 사용량을 여기에 보고한다. 받는 쪽은 `UsageMeter.$collector.withValue`로 수집기를 건다.
/// 호출 인터페이스(`AIProvider`)를 바꾸지 않고, 재시도까지 한 요청의 사용량을 모을 수 있다.
public enum UsageMeter {
    @TaskLocal public static var collector: UsageCollector?

    static func record(_ usage: TokenUsage?) {
        guard let usage else { return }
        collector?.add(usage)
    }

    /// 응답 JSON의 정수 값을 읽는다(숫자 형식이 Int · Double 어느 쪽이든).
    static func int(_ value: Any?) -> Int {
        (value as? Int) ?? (value as? Double).map { Int($0) } ?? (value as? NSNumber)?.intValue ?? 0
    }
}
