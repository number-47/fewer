import Foundation

enum CalendarLanguage: String, CaseIterable, Identifiable {
    case chinese
    case english

    static let storageKey = "calendarLanguage"

    var id: Self { self }

    var title: String {
        switch self {
        case .chinese: "中文"
        case .english: "English"
        }
    }

    var locale: Locale {
        switch self {
        case .chinese: Locale(identifier: "zh_CN")
        case .english: Locale(identifier: "en_US")
        }
    }
}
