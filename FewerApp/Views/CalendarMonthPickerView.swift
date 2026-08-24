import SwiftUI

struct CalendarMonthPickerView: View {
    @Binding var year: Int
    @Binding var month: Int

    let calendar: Calendar
    let cancel: () -> Void
    let confirm: () -> Void

    private let years = Array(1900...2100)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("跳转到年月")
                .font(.headline)

            HStack(spacing: 10) {
                Picker("年份", selection: $year) {
                    ForEach(years, id: \.self) { value in
                        Text(value, format: .number.grouping(.never))
                            .tag(value)
                    }
                }

                Picker("月份", selection: $month) {
                    ForEach(1...12, id: \.self) { value in
                        Text(monthTitle(value))
                            .tag(value)
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消", action: cancel)
                Button("跳转", action: confirm)
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
