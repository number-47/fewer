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

struct MenuBarCalendarView: View {
    static let preferredSize = NSSize(width: 400, height: 632)
    /// 月份选择器（二级弹窗）窗口标识，用于失焦关闭时识别焦点是否仍在日历弹窗体系内。
    static let monthPickerWindowIdentifier = NSUserInterfaceItemIdentifier("fewer-month-picker")

    @StateObject private var scrollCoordinator = CalendarScrollCoordinator()
    /// 网格的渲染偏移：滚动时跟随协调器像素偏移（无动画），手势结束时平滑回弹对齐。
    @State private var gridOffset: CGFloat = 0
    /// 日历网格的滚动锚点：网格从该日期所在周开始，滚轮逐行滚动时每次移动一周。
    @State private var scrollAnchor = Date.now
    @State private var selectedDate = Date.now
    @State private var isShowingMonthPicker = false
    @State private var jumpYear = Calendar.autoupdatingCurrent.component(.year, from: .now)
    @State private var jumpMonth = Calendar.autoupdatingCurrent.component(.month, from: .now)
    @ObservedObject private var currentDate = CurrentDateProvider.shared
    @ObservedObject private var systemCalendar = SystemCalendarService.shared
    @AppStorage(CalendarLanguage.storageKey) private var languageValue = CalendarLanguage.chinese.rawValue

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        calendarContent(today: currentDate.date)
            .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func calendarContent(today: Date) -> some View {
        let month = CalendarMonth(anchoredAt: scrollAnchor, today: today, calendar: calendar)

        return VStack(spacing: 12) {
            VStack(spacing: 12) {
                header(for: month)

                // 星期标题行固定不动；日期网格随滚动像素平移（跟手顺滑），
                // 网格固定 6 行等高（44 单元格 + 8 间距 = 52），行切换时余数偏移保证无缝衔接。
                HStack(spacing: 4) {
                    ForEach(month.weekdaySymbols, id: \.self) { symbol in
                        Text(symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }

                LazyVGrid(columns: columns, spacing: 8) {
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
                .offset(y: gridOffset)
                .clipped()
            }

            selectedDateSummary(in: month)

            CalendarAgendaView(
                events: systemCalendar.events(on: selectedDate, calendar: calendar),
                authorizationState: systemCalendar.authorizationState,
                reminderAuthorizationState: systemCalendar.reminderAuthorizationState,
                isLoading: systemCalendar.isLoading,
                isRequestingAccess: systemCalendar.isRequestingAccess,
                errorMessage: systemCalendar.errorMessage,
                language: language,
                requestAccess: {
                    Task {
                        await systemCalendar.requestFullAccess()
                        loadSystemEvents(for: month)
                    }
                },
                openSettings: {
                    systemCalendar.openPrivacySettings()
                }
            )

            Divider()

            footer
        }
        .padding(16)
        .onAppear {
            scrollCoordinator.onRowStep = { rows in
                scrollByRows(rows)
            }
            scrollCoordinator.start()
            loadSystemEvents(for: month)
        }
        .onDisappear {
            scrollCoordinator.stop()
        }
        .onChange(of: scrollCoordinator.offsetY) { _, newOffset in
            // 滚动中：网格跟随手指像素平移（不带动画，实时跟手）。
            gridOffset = newOffset
        }
        .onChange(of: scrollCoordinator.snapRequested) {
            // 滚动手势结束：网格平滑回弹到整行对齐，避免停在半行位置。
            withAnimation(.easeOut(duration: 0.12)) {
                gridOffset = 0
            }
        }
        .onChange(of: month.days.first?.date) {
            loadSystemEvents(for: month)
        }
        .onChange(of: languageValue) {
            loadSystemEvents(for: month)
        }
        .onChange(of: systemCalendar.changeRevision) {
            loadSystemEvents(for: month)
        }
        .onChange(of: systemCalendar.authorizationState) {
            loadSystemEvents(for: month)
        }
        .onChange(of: systemCalendar.reminderAuthorizationState) {
            loadSystemEvents(for: month)
        }
    }

    private func header(for month: CalendarMonth) -> some View {
        HStack(spacing: 6) {
            Button {
                prepareMonthJump(from: month.monthStart)
                isShowingMonthPicker = true
            } label: {
                HStack(spacing: 4) {
                    Text(month.monthStart.formatted(
                        .dateTime.year().month(.wide).locale(language.locale)
                    ))
                        .font(.title2.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(language.text(chinese: "选择年份和月份", english: "Choose Year and Month"))
            .popover(isPresented: $isShowingMonthPicker, arrowEdge: .top) {
                CalendarMonthPickerView(
                    year: $jumpYear,
                    month: $jumpMonth,
                    language: language,
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

            Spacer()

            Picker("", selection: languageBinding) {
                ForEach(CalendarLanguage.allCases) { option in
                    Text(option.shortTitle)
                        .tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 86)
            .help(language.text(chinese: "切换日历语言", english: "Change Calendar Language"))

            monthButton(
                systemImage: "chevron.left",
                title: language.text(chinese: "上个月", english: "Previous Month"),
                offset: -1
            )

            Button {
                selectToday()
            } label: {
                Image(systemName: "circle")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(language.text(chinese: "回到今天", english: "Go to Today"))

            monthButton(
                systemImage: "chevron.right",
                title: language.text(chinese: "下个月", english: "Next Month"),
                offset: 1
            )
        }
    }

    private func monthButton(systemImage: String, title: String, offset: Int) -> some View {
        Button {
            stepMonth(by: offset)
        } label: {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func dayCell(
        _ day: CalendarDay,
        calendar: Calendar,
        events: [CalendarEventItem]
    ) -> some View {
        let isSelected = calendar.isDate(day.date, inSameDayAs: selectedDate)
        let holidayTitle = CalendarEventItem.holidayTitle(in: events)

        return Button {
            selectedDate = day.date
            if !day.isInDisplayedMonth {
                scrollAnchor = day.date
            }
        } label: {
            VStack(spacing: 1) {
                Text(day.number, format: .number.grouping(.never))
                    .font(.system(size: 15, weight: day.isToday || isSelected ? .bold : .medium, design: .rounded))
                    .monospacedDigit()

                Text(holidayTitle ?? day.lunarText)
                    .font(.system(size: 10, weight: holidayTitle == nil ? .regular : .semibold))
                    .foregroundStyle(dayDetailColor(isSelected: isSelected, isHoliday: holidayTitle != nil))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                HStack(spacing: 2) {
                    ForEach(Array(events.prefix(3))) { event in
                        Circle()
                            .fill(isSelected ? Color.white.opacity(0.9) : color(for: event))
                            .frame(width: 3.5, height: 3.5)
                    }
                }
                .frame(height: 4)
            }
            .foregroundStyle(isSelected ? Color.white : day.isToday ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor)
                }
            }
            .overlay {
                if day.isToday && !isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .opacity(day.isInDisplayedMonth ? 1 : 0.52)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: day, events: events))
    }

    private var footer: some View {
        HStack {
            Button(language.text(chinese: "今天", english: "Today")) {
                selectToday()
            }

            Spacer()

            Button {
                SettingsWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape")
            }
            .help(language.text(chinese: "打开 Fewer 设置", english: "Open Fewer Settings"))
            .accessibilityLabel(language.text(chinese: "打开 Fewer 设置", english: "Open Fewer Settings"))

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help(language.text(chinese: "退出 Fewer", english: "Quit Fewer"))
            .accessibilityLabel(language.text(chinese: "退出 Fewer", english: "Quit Fewer"))
        }
        .controlSize(.small)
    }

    private func accessibilityLabel(for day: CalendarDay, events: [CalendarEventItem]) -> String {
        let dateText = day.date.formatted(
            .dateTime.weekday(.wide).year().month(.wide).day().locale(language.locale)
        )
        let baseText = day.lunarText.isEmpty ? dateText : language == .chinese
            ? "\(dateText)，农历\(day.lunarText)"
            : "\(dateText), Lunar \(day.lunarText)"
        let eventTitles = events.prefix(3).map {
            $0.title.isEmpty
                ? language.text(chinese: "无标题日程", english: "Untitled Event")
                : $0.title
        }
        guard !eventTitles.isEmpty else { return baseText }
        return language == .chinese
            ? "\(baseText)，日程：\(eventTitles.joined(separator: "、"))"
            : "\(baseText), Events: \(eventTitles.joined(separator: ", "))"
    }

    private func selectedDateSummary(in month: CalendarMonth) -> some View {
        let lunarText = month.days.first {
            calendar.isDate($0.date, inSameDayAs: selectedDate)
        }?.lunarText ?? ""

        return HStack(spacing: 8) {
            Image(systemName: "calendar.badge.checkmark")
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(selectedDate.formatted(
                    .dateTime.weekday(.wide).year().month(.wide).day().locale(language.locale)
                ))
                    .font(.callout.weight(.semibold))

                if !lunarText.isEmpty {
                    Text(language == .chinese ? "农历 \(lunarText)" : "Lunar \(lunarText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func selectToday() {
        selectedDate = currentDate.date
        let monthStart = calendar.dateInterval(of: .month, for: currentDate.date)?.start ?? currentDate.date
        scrollAnchor = monthStart
    }

    /// 滚轮逐行滚动：每滚动一步，锚点移动一周（7 天），网格随之整体平移一行。
    private func scrollByRows(_ rows: Int) {
        guard rows != 0,
              let newAnchor = calendar.date(byAdding: .day, value: rows * 7, to: scrollAnchor) else {
            return
        }
        scrollAnchor = newAnchor
    }

    /// 通过月份按钮整月切换：锚点移动到目标月的第一天，展示完整月视图。
    private func stepMonth(by offset: Int) {
        let currentMonth = calendar.dateInterval(of: .month, for: scrollAnchor)?.start ?? scrollAnchor
        scrollAnchor = calendar.date(byAdding: .month, value: offset, to: currentMonth) ?? scrollAnchor
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
        scrollAnchor = date
        selectedDate = date
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

    private var language: CalendarLanguage {
        CalendarLanguage(rawValue: languageValue) ?? .chinese
    }

    private var languageBinding: Binding<CalendarLanguage> {
        Binding(
            get: { language },
            set: { languageValue = $0.rawValue }
        )
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = language.locale
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }
}

/// 监听日历网格区域内的鼠标滚轮事件，按滚动量逐行（一周）滚动日历。
/// 网格视图的纵向偏移实时跟随滚动像素（跟手顺滑），累计满一行像素后锚点切换一周，
/// 行余数继续保留为偏移，保证行切换瞬间视觉连续、无跳变。
@MainActor
final class CalendarScrollCoordinator: ObservableObject {
    /// 日期网格视图的弱引用：滚动事件到达时实时换算其在窗口坐标系中的区域，
    /// 避免缓存窗口 frame 在弹窗重新打开/布局变化时失效导致无法滚动。
    weak var gridView: NSView?
    /// 网格视图当前的行方向像素偏移（跟随滚动余数），视图据此平移实现平滑滚动。
    @Published var offsetY: CGFloat = 0
    /// 滚动手势结束（含惯性结束）时自增，视图侧据此把网格平滑回弹到整行对齐。
    @Published var snapRequested = 0
    /// 每次滚动回调，正数向未来方向滚动、负数向过去方向滚动。
    var onRowStep: ((Int) -> Void)?

    private var monitor: Any?
    /// 累积的滚动量（像素），达到一行像素量后触发滚动，行余数保留保证顺滑。
    private var accumulatedDelta: CGFloat = 0

    /// 一行（一周）的高度：日期单元格 minHeight 44 + LazyVGrid 纵向间距 8。
    private static let rowHeight: CGFloat = 52
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
                self.offsetY = 0
            }
            if event.phase == .ended || event.phase == .cancelled {
                // 手势结束（含惯性结束）：清零累积量，视图侧平滑回弹到整行对齐。
                self.accumulatedDelta = 0
                self.snapRequested += 1
                return nil
            }

            // 传统鼠标滚轮按行滚动（每格 ±1），触控板等精确指针按像素滚动；
            // 两者都乘以灵敏度系数，控制同样的滑动量对应的实际滚动距离。
            let rawDelta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY * Self.scrollSensitivity
                : event.scrollingDeltaY * Self.rowHeight * Self.scrollSensitivity
            self.accumulatedDelta += rawDelta

            let rows = Int(self.accumulatedDelta / Self.rowHeight)
            let remainder = self.accumulatedDelta - CGFloat(rows) * Self.rowHeight
            self.accumulatedDelta = remainder
            // 视图偏移跟随行余数（符号与滚动方向一致：手指上推内容上移）：
            // 滚动未满一行时网格已随手指平移，满一行切换锚点后视觉无缝衔接。
            self.offsetY = remainder
            // 手指向下滑（scrollingDeltaY > 0）为向过去方向滚动。
            if rows != 0 {
                self.onRowStep?(-rows)
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
