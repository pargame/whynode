import Foundation

/// 코어가 화면에 내보내는 문구. 원문은 영어이고, 번역은 `Resources/<언어>.lproj/Localizable.strings`에 둔다.
/// 앱의 언어 설정(AppleLanguages)을 따른다.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
