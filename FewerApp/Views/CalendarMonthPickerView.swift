import SwiftUI

struct CalendarMonthPickerView: View {
    @Binding var year: Int
    @Binding var month: Int

    let language: CalendarLanguage
    let calendar: Calendar
    let cancel: () -> Void
    let confirm: () -> Void

    private let years = Array(1900...2100)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(language.text(chinese: "跳转到年月", english: "Jump to Month"))
                .font(.headline)

            HStack(spacing: 10) {
                Picker(language.text(chinese: "年份", english: "Year"), selection: $year) {
                    ForEach(years, id: \.self) { value in
                        Text(value, format: .number.grouping(.never))
                            .tag(value)
                    }
                }

                Picker(language.text(chinese: "月份", english: "Month"), selection: $month) {
                    ForEach(1...12, id: \.self) { value in
                        Text(monthTitle(value))
                            .tag(value)
                    }
                }
            }

            HStack {
                Spacer()
                Button(language.text(chinese: "取消", english: "Cancel"), action: cancel)
                Button(language.text(chinese: "跳转", english: "Go"), action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func monthTitle(_ month: Int) -> String {
        let symbols = calendar.monthSymbols
        guard symbols.indices.contains(month - 1) else { return "\(month)" }
        return symbols[month - 1]
    }
}
