import Foundation

/// 노드 · 글자 색 값. 프리셋은 다크 · 라이트에서 알맞게 바뀌도록 이름(토큰)으로, 사용자 지정은 "#RRGGBB"로 저장한다.
public enum NodeColor {
    public static let presets = ["red", "orange", "green", "blue", "purple"]

    public static func isValid(_ value: String) -> Bool {
        presets.contains(value) || hex(value) != nil
    }

    /// "#RRGGBB"를 0~1 RGB로 읽는다.
    public static func hex(_ value: String) -> (red: Double, green: Double, blue: Double)? {
        guard value.count == 7, value.first == "#", let number = UInt32(value.dropFirst(), radix: 16) else { return nil }
        return (Double((number >> 16) & 0xFF) / 255, Double((number >> 8) & 0xFF) / 255, Double(number & 0xFF) / 255)
    }

    public static func hexString(red: Double, green: Double, blue: Double) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
