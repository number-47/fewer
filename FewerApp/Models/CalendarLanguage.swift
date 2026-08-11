import Foundation

enum CalendarLanguage: String, CaseIterable, Identifiable {
    case chinese
    case english

    static let storageKey = "calendarLanguage"

    var id: Self { self }

    var locale: Locale {
        switch self {
        case .chinese:
            return Locale(identifier: "zh_Hans_CN")
        case .english:
            return Locale(identifier: "en_US")
        }
    }

    var shortTitle: String {
        switch self {
        case .chinese:
            return "中文"
        case .english:
            return "EN"
        }
    }

    func text(chinese: String, english: String) -> String {
        self == .chinese ? chinese : english
    }
}
