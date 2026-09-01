import AppKit
import Combine
import FewerCore
import SwiftUI

@MainActor
final class CurrentDateProvider: NSObject, ObservableObject {
    static let shared = CurrentDateProvider()

    @Published private(set) var date = Date.now

    private override init() {
        super.init()

        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(refreshDate),
            name: .NSCalendarDayChanged,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(refreshDate),
            name: .NSSystemClockDidChange,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(refreshDate),
            name: .NSSystemTimeZoneDidChange,
            object: nil
        )
    }

    @objc private func refreshDate() {
        date = .now
    }
}

/// 持久化日历浏览状态：popover 每次重建视图时保持滚动锚点和选中日期不变。
@MainActor
final class CalendarViewState: ObservableObject {
    static let shared = CalendarViewState()

    @Published var scrollAnchor: Date
    @Published var selectedDate: Date

    private init() {
        let now = Date.now
        scrollAnchor = Calendar.autoupdatingCurrent.dateInterval(of: .month, for: now)?.start ?? now
        selectedDate = now
    }
}

struct MenuBarCalendarView: View {
    enum Presentation {
        case standalone
        case embedded
    }

    static let preferredSize = NSSize(width: 710, height: 910)
    var presentation: Presentation = .standalone
    var availableWidth: CGFloat = 400
    var openSettings: (() -> Void)?
    /// 月份选择器（二级弹窗）窗口标识，用于失焦关闭时识别焦点是否仍在日历弹窗体系内。
    static let monthPickerWindowIdentifier = NSUserInterfaceItemIdentifier("fewer-month-picker")

    @StateObject private var scrollCoordinator = CalendarScrollCoordinator()
    @ObservedObject private var calendarState = CalendarViewState.shared
    @State private var isShowingMonthPicker = false
    @State private var jumpYear = Calendar.autoupdatingCurrent.component(.year, from: .now)
    @State private var jumpMonth = Calendar.autoupdatingCurrent.component(.month, from: .now)
    @ObservedObject private var currentDate = CurrentDateProvider.shared
    @ObservedObject private var systemCalendar = SystemCalendarService.shared
    @AppStorage(CalendarLanguage.storageKey) private var calendarLanguageValue = CalendarLanguage.chinese.rawValue

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        Group {
            switch presentation {
            case .standalone:
                standaloneContent(today: currentDate.date)
            case .embedded:
                embeddedContent(today: currentDate.date)
            }
        }
        .frame(width: presentation == .standalone ? Self.preferredSize.width : availableWidth)
        .onAppear(perform: start)
        .onDisappear {
            scrollCoordinator.stop()
        }
        .onChange(of: calendarState.scrollAnchor) {
            loadSystemEvents(for: displayedMonth)
        }
        .onChange(of: systemCalendar.changeRevision) {
            loadSystemEvents(for: displayedMonth)
        }
        .onChange(of: systemCalendar.authorizationState) {
            loadSystemEvents(for: displayedMonth)
        }
        .onChange(of: systemCalendar.reminderAuthorizationState) {
            loadSystemEvents(for: displayedMonth)
        }
    }

    private func embeddedContent(today: Date) -> some View {
        let month = CalendarMonth(anchoredAt: calendarState.scrollAnchor, today: today, calendar: calendar)
        return VStack(spacing: 10) {
            VStack(spacing: 10) {
                embeddedHeader(for: month)

                // 星期标题行
                HStack(spacing: 4) {
                    ForEach(month.weekdaySymbols, id: \.self) { symbol in
                        Text(symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }

                GridOffsetView(scrollCoordinator: scrollCoordinator) {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(month.days) { day in
                            dayCell(
                                day,
                                calendar: calendar,
                                events: systemCalendar.events(on: day.date, calendar: calendar)
                            )
                        }
                    }
                    .background(
                        WindowFrameReader { view in
                            scrollCoordinator.gridView = view
                        }
                    )
                }
            }

            compactSelectedDateSummary(in: month)
            agendaView(for: month, presentation: .embedded)
        }
        .padding(.horizontal, 14)
        .padding(.top, presentation == .embedded ? 6 : 14)
        .padding(.bottom, presentation == .embedded ? 4 : 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func standaloneContent(today: Date) -> some View {
        let month = CalendarMonth(anchoredAt: calendarState.scrollAnchor, today: today, calendar: calendar)
        return VStack(spacing: 0) {
            standaloneTitleBar
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    standaloneMonthCard(for: month)
                    agendaView(for: month, presentation: .standalone)
                }
                .padding(18)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    private var standaloneTitleBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("日历")
                    .font(.system(size: 24, weight: .bold))
                Text("单独菜单栏模块 · 可开发版（精修）")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            standaloneActionButton(
                title: "刷新",
                systemImage: "arrow.clockwise",
                identifier: "calendar.popover.refresh",
                action: { reloadSystemEvents(for: displayedMonth) }
            )
            standaloneActionButton(
                title: "设置",
                systemImage: "gearshape",
                identifier: "calendar.popover.settings",
                action: { openSettings?() }
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func standaloneActionButton(
        title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(width: 64, height: 58)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
    }

    private func standaloneMonthCard(for month: CalendarMonth) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Button {
                    prepareMonthJump(from: month.monthStart)
                    isShowingMonthPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Text(month.monthStart.formatted(.dateTime.year().month(.wide).locale(calendarLanguage.locale)))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .help("选择年份和月份")
                .popover(isPresented: $isShowingMonthPicker, arrowEdge: .top) {
                    monthPicker
                }

                HStack {
                    monthButton(systemImage: "chevron.left", title: "上个月", offset: -1, standalone: true)
                    Spacer()
                    monthButton(systemImage: "chevron.right", title: "下个月", offset: 1, standalone: true)
                }
            }

            HStack(spacing: 4) {
                ForEach(month.weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            GridOffsetView(scrollCoordinator: scrollCoordinator) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(standaloneDays(in: month)) { day in
                        standaloneDayCell(
                            day,
                            calendar: calendar,
                            events: systemCalendar.events(on: day.date, calendar: calendar)
                        )
                    }
                }
                .background(WindowFrameReader { scrollCoordinator.gridView = $0 })
            }

            standaloneSelectedDateSummary(in: month)
        }
        .padding(18)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func embeddedHeader(for month: CalendarMonth) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    prepareMonthJump(from: month.monthStart)
                    isShowingMonthPicker = true
                } label: {
                    HStack(spacing: 4) {
                       Text(month.monthStart.formatted(
                            .dateTime.year().month(.wide).locale(calendarLanguage.locale)
                       ))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .help("选择年份和月份")
                .popover(isPresented: $isShowingMonthPicker, arrowEdge: .top) {
                    CalendarMonthPickerView(
                        year: $jumpYear,
                        month: $jumpMonth,
                        calendar: calendar,
                        cancel: { isShowingMonthPicker = false },
                        confirm: jumpToSelectedMonth
                    )
                    .background(
                        WindowAccessor { window in
                            window?.identifier = Self.monthPickerWindowIdentifier
                        }
                    )
                }

            }

            HStack(spacing: 4) {
                Spacer()
                monthButton(
                    systemImage: "chevron.left",
                    title: "上个月",
                    offset: -1
                )

                Button {
                    selectToday()
                } label: {
                    Text("今天")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("回到今天")

                monthButton(
                    systemImage: "chevron.right",
                    title: "下个月",
                    offset: 1
                )
            }
        }
    }

    private func monthButton(
        systemImage: String,
        title: String,
        offset: Int,
        standalone: Bool = false
    ) -> some View {
        Button {
            stepMonth(by: offset)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: standalone ? 18 : 11, weight: .medium))
                .frame(width: standalone ? 38 : 22, height: standalone ? 38 : 22)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .background {
            if standalone {
                Circle().fill(Color.primary.opacity(0.05))
            }
        }
        .help(title)
        .accessibilityLabel(title)
    }

    private var monthPicker: some View {
        CalendarMonthPickerView(
            year: $jumpYear,
            month: $jumpMonth,
            calendar: calendar,
            cancel: { isShowingMonthPicker = false },
            confirm: jumpToSelectedMonth
        )
        .background(
            WindowAccessor { window in
                window?.identifier = Self.monthPickerWindowIdentifier
            }
        )
    }

    private func dayCell(
        _ day: CalendarDay,
        calendar: Calendar,
        events: [CalendarEventItem]
    ) -> some View {
        let isSelected = calendar.isDate(day.date, inSameDayAs: calendarState.selectedDate)
        let holidayTitle = CalendarEventItem.holidayTitle(in: events)

        return Button {
            calendarState.selectedDate = day.date
            if !day.isInDisplayedMonth {
                calendarState.scrollAnchor = day.date
            }
        } label: {
            VStack(spacing: 2) {
                Text(day.number, format: .number.grouping(.never))
                    .font(.system(size: 14, weight: day.isToday || isSelected ? .bold : .medium, design: .rounded))
                    .monospacedDigit()

                Text(holidayTitle ?? day.lunarText)
                    .font(.system(size: 9, weight: holidayTitle == nil ? .regular : .semibold))
                    .foregroundStyle(dayDetailColor(isSelected: isSelected, isHoliday: holidayTitle != nil))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                HStack(spacing: 2) {
                    ForEach(Array(events.prefix(3))) { event in
                        Circle()
                            .fill(isSelected ? Color.white.opacity(0.85) : color(for: event))
                            .frame(width: 3, height: 3)
                    }
                }
                .frame(height: 3)
            }
            .foregroundStyle(isSelected ? Color.white : day.isToday ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor)
                } else if day.isToday {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                }
            }
            .overlay {
                if day.isToday && !isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .opacity(day.isInDisplayedMonth ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: day, events: events))
    }

    private func standaloneDayCell(
        _ day: CalendarDay,
        calendar: Calendar,
        events: [CalendarEventItem]
    ) -> some View {
        let isSelected = calendar.isDate(day.date, inSameDayAs: calendarState.selectedDate)
        let holidayTitle = CalendarEventItem.holidayTitle(in: events)

        return Button {
            calendarState.selectedDate = day.date
            if !day.isInDisplayedMonth {
                calendarState.scrollAnchor = day.date
            }
        } label: {
            VStack(spacing: 3) {
                Text(day.number, format: .number.grouping(.never))
                    .font(.system(size: 19, weight: day.isToday || isSelected ? .bold : .medium, design: .rounded))
                    .monospacedDigit()

                Text(holidayTitle ?? day.lunarText)
                    .font(.system(size: 11, weight: holidayTitle == nil ? .regular : .semibold))
                    .foregroundStyle(dayDetailColor(isSelected: isSelected, isHoliday: holidayTitle != nil))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                HStack(spacing: 3) {
                    ForEach(Array(events.prefix(3))) { event in
                        Circle()
                            .fill(isSelected ? Color.white.opacity(0.9) : color(for: event))
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .foregroundStyle(isSelected ? Color.white : day.isToday ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 66)
            .background {
                if isSelected {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 58, height: 58)
                } else if day.isToday {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
                        .frame(width: 58, height: 58)
                }
            }
            .contentShape(Rectangle())
            .opacity(day.isInDisplayedMonth ? 1 : 0.42)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: day, events: events))
    }

    private func standaloneDays(in month: CalendarMonth) -> [CalendarDay] {
        var days = month.days
        while days.count > 35 {
            let trailingWeek = days.suffix(7)
            guard !trailingWeek.contains(where: { $0.isInDisplayedMonth }) else { break }
            days.removeLast(7)
        }
        return days
    }

    private func accessibilityLabel(for day: CalendarDay, events: [CalendarEventItem]) -> String {
        let dateText = day.date.formatted(
            .dateTime.weekday(.wide).year().month(.wide).day().locale(calendarLanguage.locale)
        )
        let baseText = day.lunarText.isEmpty ? dateText : "\(dateText)，农历\(day.lunarText)"
        let eventTitles = events.prefix(3).map {
            $0.title.isEmpty
                ? "无标题日程"
                : $0.title
        }
        guard !eventTitles.isEmpty else { return baseText }
        return "\(baseText)，日程：\(eventTitles.joined(separator: "、"))"
    }

    private func compactSelectedDateSummary(in month: CalendarMonth) -> some View {
        let lunarText = month.days.first {
            calendar.isDate($0.date, inSameDayAs: calendarState.selectedDate)
        }?.lunarText ?? ""

        return HStack(spacing: 8) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 13))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(calendarState.selectedDate.formatted(
                    .dateTime.weekday(.wide).year().month(.wide).day().locale(calendarLanguage.locale)
                ))
                    .font(.system(size: 13, weight: .semibold))

                if !lunarText.isEmpty {
                    Text("农历 \(lunarText)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func standaloneSelectedDateSummary(in month: CalendarMonth) -> some View {
        let lunarText = month.days.first {
            calendar.isDate($0.date, inSameDayAs: calendarState.selectedDate)
        }?.lunarText ?? ""
        let selectedDateText = calendarState.selectedDate.formatted(
            .dateTime.month(.defaultDigits).day().weekday(.abbreviated).locale(calendarLanguage.locale)
        )
        let prefix = calendar.isDate(calendarState.selectedDate, inSameDayAs: currentDate.date)
            ? "今天："
            : "选中日期："

        return HStack(spacing: 10) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 12, height: 12)
            Text("\(prefix)\(selectedDateText)")
            .font(.system(size: 15, weight: .medium))
            if !lunarText.isEmpty {
                Text("农历 \(lunarText)")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func agendaView(
        for month: CalendarMonth,
        presentation: CalendarAgendaView.Presentation
    ) -> some View {
        let openEvent: ((CalendarEventItem) -> Void)? = presentation == .standalone
            ? { event in openSystemCalendarApplication(for: event) }
            : nil
        return CalendarAgendaView(
            events: systemCalendar.events(on: calendarState.selectedDate, calendar: calendar),
            authorizationState: systemCalendar.authorizationState,
            reminderAuthorizationState: systemCalendar.reminderAuthorizationState,
            isLoading: systemCalendar.isLoading,
            isRequestingAccess: systemCalendar.isRequestingAccess,
            errorMessage: systemCalendar.errorMessage,
            presentation: presentation,
            title: presentation == .standalone ? agendaTitle : "日程与节假日",
            openEvent: openEvent,
            requestAccess: {
                Task {
                    await systemCalendar.requestFullAccess()
                    loadSystemEvents(for: month)
                }
            },
            openSettings: { systemCalendar.openPrivacySettings() }
        )
    }

    private func selectToday() {
        calendarState.selectedDate = currentDate.date
        calendarState.scrollAnchor = calendar.dateInterval(of: .month, for: currentDate.date)?.start ?? currentDate.date
    }

    /// 滚轮逐行滚动：每滚动一步，锚点移动一周（7 天），网格随之整体平移一行。
    private func scrollByRows(_ rows: Int) {
        guard rows != 0,
              let newAnchor = calendar.date(byAdding: .day, value: rows * 7, to: calendarState.scrollAnchor) else {
            return
        }
        calendarState.scrollAnchor = newAnchor
    }

    /// 通过月份按钮整月切换：锚点移动到目标月的第一天，展示完整月视图。
    private func stepMonth(by offset: Int) {
        let currentMonth = calendar.dateInterval(of: .month, for: calendarState.scrollAnchor)?.start ?? calendarState.scrollAnchor
        calendarState.scrollAnchor = calendar.date(byAdding: .month, value: offset, to: currentMonth) ?? calendarState.scrollAnchor
    }

    private func prepareMonthJump(from date: Date) {
        jumpYear = min(2100, max(1900, calendar.component(.year, from: date)))
        jumpMonth = calendar.component(.month, from: date)
    }

    private func jumpToSelectedMonth() {
        guard let date = CalendarMonth.startDate(
            year: jumpYear,
            month: jumpMonth,
            calendar: calendar
        ) else { return }
        calendarState.scrollAnchor = date
        calendarState.selectedDate = date
        isShowingMonthPicker = false
    }

    private func loadSystemEvents(for month: CalendarMonth) {
        guard let firstDate = month.days.first?.date,
              let lastDate = month.days.last?.date else {
            return
        }
        systemCalendar.loadEvents(
            from: firstDate,
            through: lastDate,
            calendar: calendar
        )
    }

    private func reloadSystemEvents(for month: CalendarMonth) {
        guard let firstDate = month.days.first?.date,
              let lastDate = month.days.last?.date else {
            return
        }
        systemCalendar.reloadEvents(
            from: firstDate,
            through: lastDate,
            calendar: calendar
        )
    }

    private func start() {
        scrollCoordinator.onRowStep = { rows in
            scrollByRows(rows)
        }
        scrollCoordinator.start()
        loadSystemEvents(for: displayedMonth)
    }

    private var displayedMonth: CalendarMonth {
        CalendarMonth(anchoredAt: calendarState.scrollAnchor, today: currentDate.date, calendar: calendar)
    }

    private var agendaTitle: String {
        if calendar.isDate(calendarState.selectedDate, inSameDayAs: currentDate.date) {
            return "今日事项"
        }
        let date = calendarState.selectedDate.formatted(
            .dateTime.month(.defaultDigits).day().locale(calendarLanguage.locale)
        )
        return "\(date)事项"
    }

    private func openSystemCalendarApplication(for event: CalendarEventItem) {
        let path = event.kind == .event
            ? "/System/Applications/Calendar.app"
            : "/System/Applications/Reminders.app"
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func color(for event: CalendarEventItem) -> Color {
        Color(
            red: event.color.red,
            green: event.color.green,
            blue: event.color.blue,
            opacity: event.color.opacity
        )
    }

    private func dayDetailColor(isSelected: Bool, isHoliday: Bool) -> Color {
        if isSelected {
            return .white
        }
        return isHoliday ? .red : .secondary
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = calendarLanguage.locale
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    private var calendarLanguage: CalendarLanguage {
        CalendarLanguage(rawValue: calendarLanguageValue) ?? .chinese
    }
}

/// 监听日历网格区域内的鼠标滚轮事件，按滚动量逐行（一周）滚动日历。
///
/// 性能要点：`offsetY`/`snapToken` 不再用 `@Published`，避免每次像素级滚动都使整个
/// `MenuBarCalendarView` body 失效。改为通过 `onOffsetChange`/`onSnap` 回调把偏移变化
/// 推送给 `GridOffsetView` 内部持有的 `GridOffsetStore`（`@StateObject`），让重绘范围
/// 限定在网格容器这一棵子树。
@MainActor
final class CalendarScrollCoordinator: ObservableObject {
    /// 日期网格视图的弱引用：滚动事件到达时实时换算其在窗口坐标系中的区域，
    /// 避免缓存窗口 frame 在弹窗重新打开/布局变化时失效导致无法滚动。
    weak var gridView: NSView?
    /// 网格视图当前的行方向像素偏移（跟随滚动余数）。仅供 hit-testing 读取，
    /// 不通过 `@Published` 发布——变化经 `onOffsetChange` 回调推送给 `GridOffsetStore`。
    private(set) var offsetY: CGFloat = 0
    /// 偏移变化回调：把像素偏移推送给 `GridOffsetStore`，由其 `@Published` 驱动网格重绘。
    var onOffsetChange: ((CGFloat) -> Void)?
    /// 滚动手势结束回调：通知 `GridOffsetStore` 触发平滑回弹到整行对齐。
    var onSnap: (() -> Void)?
    /// 每次滚动回调，正数向未来方向滚动、负数向过去方向滚动。
    var onRowStep: ((Int) -> Void)?

    private var monitor: Any?
    /// 累积的滚动量（像素），达到一行像素量后触发滚动，行余数保留保证顺滑。
    private var accumulatedDelta: CGFloat = 0

    /// 一行（一周）的高度：日期单元格 minHeight 42 + LazyVGrid 纵向间距 6。
    private static let rowHeight: CGFloat = 48
    /// 滚动灵敏度：缩放触控板像素与鼠标滚轮格数对应的实际滚动量（越小越慢）。
    /// 默认 0.5：触控板滑动减半、鼠标滚轮每格滚半行（两格跨一周），跨行无缝性不受影响。
    private static let scrollSensitivity: CGFloat = 0.5

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let gridView, let gridWindow = gridView.window else { return event }
            // 只处理来自日历弹窗窗口、且落在日期网格区域内的滚动事件。
            guard event.window === gridWindow else { return event }
            // 判定区域跟随网格当前的视觉偏移（offsetY），与视图实际位置一致。
            let gridFrame = gridView.convert(gridView.bounds, to: nil)
                .offsetBy(dx: 0, dy: self.offsetY)
            guard gridFrame.contains(event.locationInWindow) else { return event }

            if event.phase == .began || event.phase == .mayBegin {
                // 新手势开始：从整行对齐位置重新累积（打断上一手势的回弹动画）。
                self.accumulatedDelta = 0
                self.setOffset(0)
            }
            if event.phase == .ended || event.phase == .cancelled {
                // 手势结束（含惯性结束）：清零累积量，通知视图平滑回弹到整行对齐。
                self.accumulatedDelta = 0
                self.onSnap?()
                return nil
            }

            // 传统鼠标滚轮按行滚动（每格 ±1），触控板等精确指针按像素滚动；
            // 两者都乘以灵敏度系数，控制同样的滑动量对应的实际滚动距离。
            let rawDelta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY * Self.scrollSensitivity
                : event.scrollingDeltaY * Self.rowHeight * Self.scrollSensitivity
            self.accumulatedDelta += rawDelta

            // 单次事件最多滚动一行（±1），避免快速滑动时锚点跳过多周导致网格内容大幅重建。
            let totalRows = Int(self.accumulatedDelta / Self.rowHeight)
            let stepRows = max(-1, min(1, totalRows))
            self.accumulatedDelta -= CGFloat(stepRows) * Self.rowHeight
            // 视图偏移跟随行余数（符号与滚动方向一致：手指上推内容上移）：
            // 滚动未满一行时网格已随手指平移，满一行切换锚点后视觉无缝衔接。
            self.setOffset(self.accumulatedDelta)
            // 手指向下滑（scrollingDeltaY > 0）为向过去方向滚动。
            if stepRows != 0 {
                self.onRowStep?(-stepRows)
            }
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        accumulatedDelta = 0
    }

    /// 统一更新偏移并通知 `GridOffsetStore`，保证 hit-test 与渲染一致。
    private func setOffset(_ value: CGFloat) {
        offsetY = value
        onOffsetChange?(value)
    }
}

/// 隔离网格偏移渲染的 ObservableObject，由 `GridOffsetView` 以 `@StateObject` 持有。
///
/// `offset` 变化只会使 `GridOffsetView` 的 body 失效，不会波及 `MenuBarCalendarView`
/// 父 body，从而把 SwiftUI 树重建范围限制在网格容器子树。
@MainActor
private final class GridOffsetStore: ObservableObject {
    @Published var offset: CGFloat = 0
    @Published var snapToken = 0
}

/// 承载日期网格并应用像素级偏移的容器视图。
///
/// 关键架构决策：`GridOffsetStore` 以 `@StateObject` 持有在此视图内部，而非父视图。
/// 滚动时只有本视图 body 重新求值；`content` 作为同一 view 值传入，SwiftUI 跳过其
/// 子树重建，从而避免 `LazyVGrid` 中 42 个日期单元格的 diff 开销。父 body 不失效。
private struct GridOffsetView<Content: View>: View {
    let scrollCoordinator: CalendarScrollCoordinator
    @ViewBuilder var content: Content
    @StateObject private var store = GridOffsetStore()

    var body: some View {
        content
            .offset(y: store.offset)
            .clipped()
            .onAppear {
                scrollCoordinator.onOffsetChange = { [weak store] offset in
                    store?.offset = offset
                }
                scrollCoordinator.onSnap = { [weak store] in
                    store?.snapToken &+= 1
                }
            }
            .onChange(of: store.snapToken) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    store.offset = 0
                }
            }
    }
}

/// 向上报告承载视图所在的 NSWindow（用于给二级弹窗标记窗口标识）。
private struct WindowAccessor: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        WindowReportingView(onChange: onChange)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowReportingView)?.onChange = onChange
        (nsView as? WindowReportingView)?.report()
    }

    final class WindowReportingView: NSView {
        var onChange: (NSWindow?) -> Void

        init(onChange: @escaping (NSWindow?) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            report()
        }

        func report() {
            onChange(window)
        }
    }
}

/// 向上报告承载视图的引用（含其内部子视图的布局变化）。
private struct WindowFrameReader: NSViewRepresentable {
    let onChange: (NSView?) -> Void

    func makeNSView(context: Context) -> NSView {
        FrameReportingView(onChange: onChange)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? FrameReportingView)?.onChange = onChange
        (nsView as? FrameReportingView)?.report()
    }

    final class FrameReportingView: NSView {
        var onChange: (NSView?) -> Void

        init(onChange: @escaping (NSView?) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        override var intrinsicContentSize: NSSize {
            .zero
        }

        func report() {
            onChange(self)
        }
    }
}
