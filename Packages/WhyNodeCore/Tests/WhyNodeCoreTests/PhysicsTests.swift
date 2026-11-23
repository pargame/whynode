import Foundation
import Testing
@testable import WhyNodeCore

private let t0 = Timestamp.date(from: "2026-11-23T01:00:00.000Z")!

/// 루트에 자식 여럿, 첫 자식에 손자 여럿을 단 지도. 일부러 한 점에 몰아 겹치게 둔다.
private func crowdedMap(children: Int = 6, grandchildren: Int = 4) -> MindMap {
    var map = MindMap.new(now: t0)
    map.setRootQuestion("주제", now: t0)
    var first: WID?
    for i in 0..<children {
        let id = map.addCustomChild(of: map.rootId, question: "자식 \(i)", now: t0)!
        first = first ?? id
    }
    for i in 0..<grandchildren {
        _ = map.addCustomChild(of: first!, question: "손자 \(i)", now: t0)
    }
    for node in map.nodes where node.id != map.rootId {
        map.move(node.id, to: (10, 10), pinned: true, now: t0)
    }
    return map
}

private func distance(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
    ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
}

@Suite("시뮬레이션")
struct PhysicsTests {
    @Test func 안정되면_스스로_멈춘다() {
        var sim = ForceSimulation(map: crowdedMap(), settings: .default)
        var ticks = 0
        while sim.tick() { ticks += 1 }
        #expect(sim.isSettled)
        #expect(ticks < ForceSimulation.maxTicks)
        let again = sim.tick()
        #expect(!again)
    }

    @Test func 루트는_움직이지_않고_고정된_노드도_옮긴다() throws {
        let map = crowdedMap()
        var sim = ForceSimulation(map: map, settings: .default)
        while sim.tick() {}
        let root = try #require(sim.position(of: map.rootId))
        #expect(root.x == map.root.position.x && root.y == map.root.position.y)

        var arranged = map
        arranged.arrange(sim.positions)
        #expect(arranged.root.position == map.root.position)
        #expect(arranged.nodes.filter { $0.id != map.rootId }.allSatisfy { $0.position.x != 10 || $0.position.y != 10 })
    }

    @Test func 정리하면_노드가_겹치지_않는다() {
        let map = crowdedMap()
        var sim = ForceSimulation(map: map, settings: .default)
        while sim.tick() {}
        let points = map.nodes.compactMap { sim.position(of: $0.id) }
        var closest = Double.infinity
        for i in 0..<points.count {
            for j in (i + 1)..<points.count { closest = min(closest, distance(points[i], points[j])) }
        }
        #expect(closest > ForceSimulation.nodeRadius * 2)
    }

    @Test func 링크_거리를_늘리면_자식이_멀어진다() throws {
        let map = crowdedMap(children: 3, grandchildren: 0)
        func meanDistance(_ settings: PhysicsSettings) -> Double {
            var sim = ForceSimulation(map: map, settings: settings)
            while sim.tick() {}
            let root = sim.position(of: map.rootId)!
            let children = map.childIDs(of: map.rootId).compactMap { sim.position(of: $0) }
            return children.map { distance($0, root) }.reduce(0, +) / Double(children.count)
        }
        var near = PhysicsSettings.default
        near.linkDistance = 200
        var far = PhysicsSettings.default
        far.linkDistance = 500
        #expect(meanDistance(far) > meanDistance(near) + 150)
    }

    @Test func 잡은_노드는_손가락_위치에_있고_놓으면_다시_움직인다() throws {
        let map = crowdedMap(children: 3, grandchildren: 0)
        let child = map.childIDs(of: map.rootId)[0]
        var sim = ForceSimulation(map: map, settings: .default)
        sim.hold(child, at: (900, 900))
        for _ in 0..<30 { sim.tick() }
        let held = try #require(sim.position(of: child))
        #expect(held.x == 900 && held.y == 900)

        sim.release(child)
        sim.reheat()
        for _ in 0..<30 { sim.tick() }
        let released = try #require(sim.position(of: child))
        #expect(released.x != 900 || released.y != 900)
    }

    @Test func 노드가_늘어도_기존_위치를_유지한다() throws {
        var map = crowdedMap(children: 2, grandchildren: 0)
        var sim = ForceSimulation(map: map, settings: .default)
        for _ in 0..<50 { sim.tick() }
        let existing = map.childIDs(of: map.rootId)[0]
        let before = try #require(sim.position(of: existing))
        _ = map.addCustomChild(of: map.rootId, question: "새 자식", now: t0)
        sim.sync(with: map)
        let after = try #require(sim.position(of: existing))
        #expect(before.x == after.x && before.y == after.y)
        #expect(sim.positions.count == map.nodes.count)
    }

    @Test func 범위를_벗어난_조절값은_맞춘다() {
        let wild = PhysicsSettings(repel: -5, tension: 3, linkDistance: .nan, gravity: 0.5).clamped
        #expect(wild == PhysicsSettings(repel: 0, tension: 1, linkDistance: 40, gravity: 0.5))
    }
}
