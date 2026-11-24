import Foundation

/// 새 노드의 초기 배치. 힘 기반 부분 배치(SPEC 8.4)를 붙이기 전까지의 기본 배치 규칙이다.
public enum Layout {
    public static let childDistance = 240.0
    static let spread = Double.pi / 2.2

    /// 부모에서 조부모 반대 방향으로 부채꼴을 그리며 자식을 놓는다.
    static func childPosition(in map: MindMap, parentId: WID) -> Position {
        guard let parent = map[parentId] else { return Position() }
        let base: Double
        if let gid = parent.parentId, let grand = map[gid] {
            base = atan2(parent.position.y - grand.position.y, parent.position.x - grand.position.x)
        } else {
            base = -Double.pi / 2
        }
        let index = map.childIDs(of: parentId).count
        let angle: Double
        if parent.parentId == nil {
            // 루트는 사방으로 펼친다
            angle = base + Double(index) * (2 * Double.pi / 6)
        } else {
            let step = spread / 2
            let offset = index == 0 ? 0 : Double((index + 1) / 2) * step * (index.isMultiple(of: 2) ? -1 : 1)
            angle = base + offset
        }
        let ring = Double(index / 6)
        // 큰 부모는 그만큼 더 떨어뜨린다(기본 크기에서 240).
        let distance = childDistance + (parent.sizeScale - 1) * ForceSimulation.nodeRadius + ring * 120
        return Position(x: parent.position.x + cos(angle) * distance, y: parent.position.y + sin(angle) * distance)
    }
}
