import Foundation
import Synchronization

/// 화면 문구 언어. 앱이 설정에서 고른 언어를 넣으면, 다시 켜지 않아도 코어 문구가 그 언어로 나온다.
public enum CoreLanguage {
    private static let current = Mutex(Locale.current)

    public static var locale: Locale {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}

/// 코어가 화면에 내보내는 문구. 원문은 영어이고, 번역은 `Resources/<언어>.lproj/Localizable.strings`에 둔다.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: LocalizedStringResource(key, locale: CoreLanguage.locale, bundle: .atURL(Bundle.module.bundleURL)))
}
