import Foundation
import WhyNodeCore

/// 코드에서 만드는 화면 문구(알림 · 실행 취소 이름 · 메뉴 등)를 설정에서 고른 언어로 바꾼다.
/// SwiftUI의 Text · Button 문구는 `.environment(\\.locale)`로 바뀌고, 이 함수는 그 밖의 문자열에 쓴다.
nonisolated func tr(_ key: String.LocalizationValue) -> String {
    String(localized: LocalizedStringResource(key, locale: CoreLanguage.locale))
}

extension LocalizedStringResource {
    /// 설정에서 고른 언어로 옮긴 문자열
    nonisolated var inAppLanguage: String {
        var resource = self
        resource.locale = CoreLanguage.locale
        return String(localized: resource)
    }
}
