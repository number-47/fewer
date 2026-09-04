import SwiftUI

struct CalendarMonthPickerView: View {
    @Binding var year: Int
    @Binding var month: Int

    let calendar: Calendar
    let cancel: () -> Void
    let confirm: () -> Void

    private let yearRange = 1900...2100

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("跳转到年月")
                .font(.headline)

            HStack(spacing: 8) {
                stepButton(
                    systemImage: "chevron.left",
                    title: "上一年",
                    identifier: "calendar.monthPicker.previousYear",
                    isDisabled: year <= yearRange.lowerBound
                ) {
                    year -= 1
                }

                Picker("年份", selection: $year) {
                    ForEach(yearRange, id: \.self) { value in
                        Text(value, format: .number.grouping(.never))
                            .tag(value)
                    }
                }

                stepButton(
                    systemImage: "chevron.right",
                    title: "下一年",
                    identifier: "calendar.monthPicker.nextYear",
                    isDisabled: year >= yearRange.upperBound
                ) {
                    year += 1
                }
            }

            HStack(spacing: 8) {
                stepButton(
                    systemImage: "chevron.left",
                    title: "上个月",
                    identifier: "calendar.monthPicker.previousMonth",
                    isDisabled: year <= yearRange.lowerBound && month <= 1
                ) {
                    stepMonth(by: -1)
                }

                Picker("月份", selection: $month) {
                    ForEach(1...12, id: \.self) { value in
                        Text(monthTitle(value))
                            .tag(value)
                    }
                }

                stepButton(
                    systemImage: "chevron.right",
                    title: "下个月",
                    identifier: "calendar.monthPicker.nextMonth",
                    isDisabled: year >= yearRange.upperBound && month >= 12
                ) {
                    stepMonth(by: 1)
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

    private func stepMonth(by offset: Int) {
        let targetMonth = month + offset
        if targetMonth < 1 {
            guard year > yearRange.lowerBound else { return }
            year -= 1
            month = 12
        } else if targetMonth > 12 {
            guard year < yearRange.upperBound else { return }
            year += 1
            month = 1
        } else {
            month = targetMonth
        }
    }

    private func stepButton(
        systemImage: String,
        title: String,
        identifier: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(title)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
    }
}
