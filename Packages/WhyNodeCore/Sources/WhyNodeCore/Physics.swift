import Foundation

/// 시뮬레이션의 조절값 (SPEC 2.6). 화면의 슬라이더 · 입력칸과 1:1로 대응한다.
/// 두 값 모두 0~10 눈금이고 단위에 의미는 없다. 실제 힘은 `ForceSimulation`이 눈금마다 다른 배율로 환산한다.
public struct PhysicsSettings: Codable, Equatable, Sendable {
    /// 노드끼리 밀어내는 힘
    public var repel: Double
    /// 선으로 이어진 노드를 원 가장자리가 맞닿는 거리로 당기는 힘
    public var tension: Double

    /// 주인이 실제로 맞춰 본 값(옛 눈금 반발력 5 · 장력 0.5 · 링크 거리 0 · 중심력 0, 2026-11-24)을 눈금 가운데 5로 맞췄다.
    public static let `default` = PhysicsSettings(repel: 5, tension: 5)

    public static let range: ClosedRange<Double> = 0...10

    public init(repel: Double, tension: Double) {
        self.repel = repel
        self.tension = tension
    }

    /// 범위를 벗어난 값(직접 입력 · 이전 저장값)을 허용 범위로 맞춘다.
    public var clamped: PhysicsSettings {
        func clamp(_ v: Double) -> Double { v.isFinite ? min(max(v, Self.range.lowerBound), Self.range.upperBound) : Self.range.lowerBound }
        // 장력은 1 단위로만 고른다.
        return PhysicsSettings(repel: clamp(repel), tension: clamp(tension).rounded())
    }
}

/// 버튼으로 시작해 안정되면 멈추는 힘 기반 배치 (SPEC 2.6, 8.4).
/// d3-force와 같은 방식으로 온도(alpha)가 식어 가며, 루트와 사용자가 잡고 있는 노드만 고정한다.
public struct ForceSimulation: Sendable {
    public static let nodeRadius = 70.0
    /// 원끼리 최소 이만큼(양쪽 합 2배) 떨어진다. 장력이 원을 맞닿게 당겨도 선이 조금 보이도록 작게 둔다.
    static let collisionPadding = 4.0
    static let alphaMin = 0.001
    static let alphaDecay = 1 - pow(alphaMin, 1.0 / 300)
    static let velocityDecay = 0.4
    /// 가장 빠른 노드의 한 틱 이동량이 이 값보다 작으면 안정된 것으로 본다.
    static let restSpeed = 0.05
    static let maxTicks = 600
    /// 눈금 1이 갖는 실제 힘의 크기. 반발력 눈금은 옛 눈금과 같고, 장력 눈금 5가 옛 장력 0.5다.
    static let repelScale = 500.0
    static let tensionScale = 0.1
    /// 한 틱 최대 이동량. 정상 범위에서는 닿지 않고, 발산할 때 좌표가 무한대가 되는 것만 막는다.
    static let maxSpeed = 100.0

    public var settings: PhysicsSettings
    public private(set) var alpha = 1.0
    public private(set) var ticks = 0

    private var ids: [WID] = []
    private var index: [WID: Int] = [:]
    private var position: [SIMD2<Double>] = []
    private var velocity: [SIMD2<Double>] = []
    private var fixed: [SIMD2<Double>?] = []
    /// 노드별 반지름(기본 70 × 노드 크기)
    private var radius: [Double] = []
    private var links: [(source: Int, target: Int, bias: Double)] = []
    private let rootId: WID
    /// 움직일 수 있는 노드. nil이면 루트를 뺀 전부이고, 값이 있으면 나머지는 제자리에 고정된 장애물이 된다 (SPEC 8.4 부분 계산).
    public private(set) var movable: Set<WID>?

    /// `alpha`는 시작 온도. 새 노드 주변만 정리하는 부분 계산은 낮게 시작해 짧게 끝낸다.
    public init(map: MindMap, settings: PhysicsSettings, movable: Set<WID>? = nil, alpha: Double = 1) {
        self.settings = settings.clamped
        rootId = map.rootId
        self.movable = movable
        self.alpha = alpha
        sync(with: map)
    }

    private func isAnchored(_ id: WID) -> Bool {
        id == rootId || (movable.map { !$0.contains(id) } ?? false)
    }

    /// 움직일 수 있는 노드를 바꾼다. 범위 밖이 된 노드는 지금 자리에 고정하고, 범위 안이 된 노드는 풀어 준다.
    public mutating func setMovable(_ ids: Set<WID>?) {
        movable = ids
        for (i, id) in self.ids.enumerated() {
            fixed[i] = isAnchored(id) ? position[i] : nil
        }
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
                newFixed.append(isAnchored(node.id) ? p : nil)
            }
        }
        ids = newIds
        radius = map.nodes.map { Self.nodeRadius * $0.sizeScale }
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
        fixed[i] = isAnchored(id) ? position[i] : nil
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
        applyCollision(n)

        var fastest = 0.0
        for i in 0..<n {
            if let f = fixed[i] {
                position[i] = f
                velocity[i] = .zero
                continue
            }
            velocity[i] *= 1 - Self.velocityDecay
            let speed2 = (velocity[i] * velocity[i]).sum()
            if !speed2.isFinite {
                velocity[i] = .zero
            } else if speed2 > Self.maxSpeed * Self.maxSpeed {
                velocity[i] *= Self.maxSpeed / speed2.squareRoot()
            }
            position[i] += velocity[i]
            fastest = max(fastest, (velocity[i] * velocity[i]).sum())
        }
        // 처음 몇 틱은 속도가 붙기 전이므로 건너뛴다.
        if ticks > 20, fastest.squareRoot() < Self.restSpeed { alpha = 0 }
        return !isSettled
    }

    private mutating func applyLinks() {
        let strength = settings.tension * Self.tensionScale
        guard strength > 0 else { return }
        for link in links {
            var d = (position[link.target] + velocity[link.target]) - (position[link.source] + velocity[link.source])
            if d == .zero { d = jitter(link.target) }
            let length = (d * d).sum().squareRoot()
            // 목표는 두 원의 가장자리가 맞닿는 거리. 실제 간격은 반발력과의 균형으로 정해진다.
            let target = radius[link.source] + radius[link.target]
            let k = (length - target) / length * alpha * strength
            let delta = d * k
            // 한쪽 끝이 고정이면 움직이는 쪽이 이동을 전부 맡는다. 고정된 쪽 몫은 어차피 버려진다.
            let bias = fixed[link.source] != nil ? 1 : fixed[link.target] != nil ? 0 : link.bias
            velocity[link.target] -= delta * bias
            velocity[link.source] += delta * (1 - bias)
        }
    }

    /// 모든 쌍을 계산한다. 정리는 버튼으로 몇 초만 도는 작업이라 수백 개까지는 충분하다.
    private mutating func applyRepel(_ n: Int) {
        let strength = settings.repel * Self.repelScale
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

    /// 노드 원끼리 겹치지 않게 떼어 놓는다. 온도와 상관없이 항상 작동한다.
    private mutating func applyCollision(_ n: Int) {
        guard n > 1 else { return }
        for i in 0..<(n - 1) {
            for j in (i + 1)..<n {
                let minDistance = radius[i] + radius[j] + 2 * Self.collisionPadding
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
