import FewerCore
import SwiftUI

struct CalendarAgendaView: View {
    enum Presentation {
        case standalone
        case embedded
    }

    let events: [CalendarEventItem]
    let authorizationState: SystemCalendarAuthorizationState
    let reminderAuthorizationState: SystemCalendarAuthorizationState
    let isLoading: Bool
    let isRequestingAccess: Bool
    let errorMessage: String?
    var presentation: Presentation = .embedded
    var title: String = "日程与节假日"
    var openEvent: ((CalendarEventItem) -> Void)?
    let requestAccess: () -> Void
    let openSettings: () -> Void

    var body: some View {
        Group {
            switch presentation {
            case .standalone:
                standaloneContent
            case .embedded:
                embeddedContent
            }
        }
    }

    private var embeddedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            agendaHeader(title: title, large: false)
            content
        }
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: .infinity, alignment: .topLeading)
    }

    private var standaloneContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            agendaHeader(title: title, large: true)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 144, maxHeight: 280, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func agendaHeader(title: String, large: Bool) -> some View {
        HStack {
            Text(title)
                .font(large ? .system(size: 18, weight: .semibold) : .caption.weight(.semibold))
                .foregroundStyle(large ? .primary : .secondary)

            Spacer()

            if large {
                Text("\(events.count) 项")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if isLoading {
                ProgressView()
                    .controlSize(large ? .small : .mini)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if hasAnyReadAccess {
            VStack(alignment: .leading, spacing: 5) {
                if events.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(events) { event in
                                eventRow(event)
                            }
                        }
                    }
                }

                if let missingAccess = missingAccessPrompt {
                    compactPermissionPrompt(missingAccess)
                }
            }
        } else if canRequestAccess {
            permissionPrompt(
                message: "允许读取系统日历和提醒事项后，可展示节假日、日程与计划任务。",
                buttonTitle: "允许访问",
                action: requestAccess
            )
        } else {
            permissionPrompt(
                message: "需要系统日历或提醒事项的完整读取权限。",
                buttonTitle: "打开系统设置",
                action: openSettings
            )
        }
    }

    private var hasAnyReadAccess: Bool {
        authorizationState == .fullAccess || reminderAuthorizationState == .fullAccess
    }

    private var canRequestAccess: Bool {
        isRequestable(authorizationState) || isRequestable(reminderAuthorizationState)
    }

    private var missingAccessPrompt: MissingAccessPrompt? {
        if reminderAuthorizationState != .fullAccess {
            return MissingAccessPrompt(
                title: "显示计划事项",
                action: isRequestable(reminderAuthorizationState) ? requestAccess : openSettings
            )
        }
        if authorizationState != .fullAccess {
           return MissingAccessPrompt(
                title: "显示日历日程",
                action: isRequestable(authorizationState) ? requestAccess : openSettings
            )
        }
        return nil
    }

    private func isRequestable(_ state: SystemCalendarAuthorizationState) -> Bool {
        state == .notDetermined || state == .writeOnly
    }

    private func compactPermissionPrompt(_ prompt: MissingAccessPrompt) -> some View {
        Button(action: prompt.action) {
            Label(prompt.title, systemImage: "checklist")
                .font(.caption)
        }
        .buttonStyle(.link)
        .controlSize(.small)
        .disabled(isRequestingAccess)
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.minus")
                .foregroundStyle(.secondary)
            Text("当天没有日程或节假日")
                .font(presentation == .standalone ? .system(size: 14) : .caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func permissionPrompt(
        message: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(errorMessage ?? message)
                .font(.caption)
                .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)

            Button(buttonTitle, action: action)
                .controlSize(.small)
                .disabled(isRequestingAccess)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func eventRow(_ event: CalendarEventItem) -> some View {
        if presentation == .standalone {
            Button(action: { openEvent?(event) }) {
                eventRowContent(event, standalone: true)
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            eventRowContent(event, standalone: false)
        }
    }

    @ViewBuilder
    private func eventRowContent(_ event: CalendarEventItem, standalone: Bool) -> some View {
        if standalone {
            HStack(spacing: 10) {
                Circle()
                    .fill(color(for: event))
                    .frame(width: 12, height: 12)

                Text(event.title.isEmpty ? "无标题日程" : event.title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)

                Text(timeRangeText(for: event))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(event.calendarTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(eventTypeText(for: event))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            embeddedEventRowContent(event)
        }
    }

    private func embeddedEventRowContent(_ event: CalendarEventItem) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(color(for: event))
                .frame(width: 7, height: 7)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title.isEmpty
                     ? "无标题日程"
                     : event.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(embeddedTimeText(for: event))
                    Text(event.calendarTitle)
                        .lineLimit(1)

                    if event.kind == .reminder {
                       Label(
                           event.isCompleted
                               ? "已完成"
                               : "计划",
                            systemImage: event.isCompleted ? "checkmark.circle.fill" : "checklist"
                        )
                        .labelStyle(.titleAndIcon)
                    }

                    if event.isSubscription {
                       Label(
                            "订阅",
                            systemImage: "dot.radiowaves.left.and.right"
                        )
                        .labelStyle(.titleAndIcon)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeRangeText(for event: CalendarEventItem) -> String {
        if event.isAllDay {
            return "全天"
        }
        let style = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(event.startDate.formatted(style)) – \(event.endDate.formatted(style))"
    }

    private func embeddedTimeText(for event: CalendarEventItem) -> String {
        if event.isAllDay {
            return "全天"
        }
        return event.startDate.formatted(.dateTime.hour().minute())
    }

    private func eventTypeText(for event: CalendarEventItem) -> String {
        if event.kind == .reminder {
            return event.isCompleted ? "提醒·已完成" : "提醒"
        }
        return event.isSubscription ? "订阅日历" : "日程"
    }

    private func color(for event: CalendarEventItem) -> Color {
        Color(
            red: event.color.red,
            green: event.color.green,
            blue: event.color.blue,
            opacity: event.color.opacity
        )
    }
}

private struct MissingAccessPrompt {
    let title: String
    let action: () -> Void
}
