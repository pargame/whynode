import Foundation

/// 시뮬레이션의 조절값 (SPEC 2.6). 화면의 슬라이더 · 입력칸과 1:1로 대응한다.
public struct PhysicsSettings: Codable, Equatable, Sendable {
    /// 노드끼리 밀어내는 힘
    public var repel: Double
    /// 선으로 이어진 노드가 링크 거리로 돌아가려는 힘
    public var tension: Double
    /// 선의 목표 길이
    public var linkDistance: Double
    /// 루트 쪽으로 모으는 힘
    public var gravity: Double

    public static let `default` = PhysicsSettings(repel: 8, tension: 0.6, linkDistance: 240, gravity: 0.1)

    public static let repelRange: ClosedRange<Double> = 0...20
    public static let tensionRange: ClosedRange<Double> = 0...1
    public static let linkDistanceRange: ClosedRange<Double> = 40...600
    public static let gravityRange: ClosedRange<Double> = 0...1

    public init(repel: Double, tension: Double, linkDistance: Double, gravity: Double) {
        self.repel = repel
        self.tension = tension
        self.linkDistance = linkDistance
        self.gravity = gravity
    }

    /// 범위를 벗어난 값(직접 입력 · 이전 저장값)을 허용 범위로 맞춘다.
    public var clamped: PhysicsSettings {
        func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : r.lowerBound }
        return PhysicsSettings(
            repel: clamp(repel, Self.repelRange),
            tension: clamp(tension, Self.tensionRange),
            linkDistance: clamp(linkDistance, Self.linkDistanceRange),
            gravity: clamp(gravity, Self.gravityRange)
        )
    }
}

/// 버튼으로 시작해 안정되면 멈추는 힘 기반 배치 (SPEC 2.6, 8.4).
/// d3-force와 같은 방식으로 온도(alpha)가 식어 가며, 루트와 사용자가 잡고 있는 노드만 고정한다.
public struct ForceSimulation: Sendable {
    public static let nodeRadius = 70.0
    static let collisionPadding = 18.0
    static let alphaMin = 0.001
    static let alphaDecay = 1 - pow(alphaMin, 1.0 / 300)
    static let velocityDecay = 0.4
    /// 가장 빠른 노드의 한 틱 이동량이 이 값보다 작으면 안정된 것으로 본다.
    static let restSpeed = 0.05
    static let maxTicks = 600

    public var settings: PhysicsSettings
    public private(set) var alpha = 1.0
    public private(set) var ticks = 0

    private var ids: [WID] = []
    private var index: [WID: Int] = [:]
    private var position: [SIMD2<Double>] = []
    private var velocity: [SIMD2<Double>] = []
    private var fixed: [SIMD2<Double>?] = []
    private var links: [(source: Int, target: Int, bias: Double)] = []
    private let rootId: WID

    public init(map: MindMap, settings: PhysicsSettings) {
        self.settings = settings.clamped
        rootId = map.rootId
        sync(with: map)
    }

    public var isSettled: Bool { alpha < Self.alphaMin || ticks >= Self.maxTicks }

    public var positions: [WID: (x: Double, y: Double)] {
        var result: [WID: (x: Double, y: Double)] = [:]
        for (i, id) in ids.enumerated() { result[id] = (position[i].x, position[i].y) }
        return result
    }

    public func position(of id: WID) -> (x: Double, y: Double)? {
        guard let i = index[id] else { return nil }
        return (position[i].x, position[i].y)
    }

    /// 노드가 추가 · 삭제되면 남은 노드의 현재 위치와 속도는 유지한 채 다시 맞춘다.
    public mutating func sync(with map: MindMap) {
        var newIds: [WID] = []
        var newPosition: [SIMD2<Double>] = []
        var newVelocity: [SIMD2<Double>] = []
        var newFixed: [SIMD2<Double>?] = []
        for node in map.nodes {
            newIds.append(node.id)
            if let i = index[node.id] {
                newPosition.append(position[i])
                newVelocity.append(velocity[i])
                newFixed.append(fixed[i])
            } else {
                let p = SIMD2(node.position.x, node.position.y)
                newPosition.append(p)
                newVelocity.append(.zero)
                newFixed.append(node.id == rootId ? p : nil)
            }
        }
        ids = newIds
        position = newPosition
        velocity = newVelocity
        fixed = newFixed
        index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })

        var degree = [Int](repeating: 0, count: ids.count)
        var pairs: [(Int, Int)] = []
        for node in map.nodes {
            guard let pid = node.parentId, let s = index[pid], let t = index[node.id] else { continue }
            pairs.append((s, t))
            degree[s] += 1
            degree[t] += 1
        }
        // 연결이 많은 노드는 덜 끌려가도록 양쪽 연결 수로 이동 몫을 나눈다.
        links = pairs.map { s, t in (s, t, Double(degree[s]) / Double(degree[s] + degree[t])) }
    }

    /// 다시 데운다. 조절값을 바꾸거나 노드를 잡으면 멈췄던 배치가 다시 움직인다.
    public mutating func reheat(to value: Double = 1) {
        alpha = max(alpha, value)
        ticks = 0
    }

    /// 사용자가 잡은 노드는 손가락 위치에 고정한다. 루트는 놓아도 고정이 유지된다.
    public mutating func hold(_ id: WID, at point: (x: Double, y: Double)) {
        guard let i = index[id] else { return }
        let p = SIMD2(point.x, point.y)
        fixed[i] = p
        position[i] = p
        velocity[i] = .zero
    }

    public mutating func release(_ id: WID) {
        guard let i = index[id], id != rootId else { return }
        fixed[i] = nil
    }

    /// 한 틱 진행한다. 안정되면 false를 돌려준다.
    @discardableResult
    public mutating func tick() -> Bool {
        guard !isSettled else { return false }
        ticks += 1
        alpha += (0 - alpha) * Self.alphaDecay
        let n = ids.count

        applyLinks()
        applyRepel(n)
        applyGravity(n)
        applyCollision(n)

        var fastest = 0.0
        for i in 0..<n {
            if let f = fixed[i] {
                position[i] = f
                velocity[i] = .zero
                continue
            }
            velocity[i] *= 1 - Self.velocityDecay
            position[i] += velocity[i]
            fastest = max(fastest, (velocity[i] * velocity[i]).sum())
        }
        // 처음 몇 틱은 속도가 붙기 전이므로 건너뛴다.
        if ticks > 20, fastest.squareRoot() < Self.restSpeed { alpha = 0 }
        return !isSettled
    }

    private mutating func applyLinks() {
        let strength = settings.tension
        guard strength > 0 else { return }
        for link in links {
            var d = (position[link.target] + velocity[link.target]) - (position[link.source] + velocity[link.source])
            if d == .zero { d = jitter(link.target) }
            let length = (d * d).sum().squareRoot()
            let k = (length - settings.linkDistance) / length * alpha * strength
            let delta = d * k
            velocity[link.target] -= delta * link.bias
            velocity[link.source] += delta * (1 - link.bias)
        }
    }

    /// 모든 쌍을 계산한다. 정리는 버튼으로 몇 초만 도는 작업이라 수백 개까지는 충분하다.
    private mutating func applyRepel(_ n: Int) {
        let strength = settings.repel * 500
        guard strength > 0, n > 1 else { return }
        for i in 0..<(n - 1) {
            for j in (i + 1)..<n {
                var d = position[j] - position[i]
                if d == .zero { d = jitter(j) }
                let l2 = max((d * d).sum(), 400)
                let push = d * (strength * alpha / l2)
                velocity[i] -= push
                velocity[j] += push
            }
        }
    }

    private mutating func applyGravity(_ n: Int) {
        let strength = settings.gravity * 0.05
        guard strength > 0, let r = index[rootId] else { return }
        let center = position[r]
        for i in 0..<n where i != r {
            velocity[i] += (center - position[i]) * (strength * alpha)
        }
    }

    /// 노드 원끼리 겹치지 않게 떼어 놓는다. 온도와 상관없이 항상 작동한다.
    private mutating func applyCollision(_ n: Int) {
        let minDistance = 2 * (Self.nodeRadius + Self.collisionPadding)
        guard n > 1 else { return }
        for i in 0..<(n - 1) {
            for j in (i + 1)..<n {
                var d = (position[j] + velocity[j]) - (position[i] + velocity[i])
                let l2 = (d * d).sum()
                guard l2 < minDistance * minDistance else { continue }
                if l2 == 0 { d = jitter(j) }
                let length = max(l2.squareRoot(), 1e-6)
                let push = d * ((minDistance - length) / length * 0.35)
                velocity[i] -= push
                velocity[j] += push
            }
        }
    }

    /// 같은 자리에 겹친 노드를 결정적으로 살짝 떼어 놓는다.
    private func jitter(_ i: Int) -> SIMD2<Double> {
        let angle = Double(i) * 2.399963
        return SIMD2(cos(angle), sin(angle)) * 1e-3
    }
}
