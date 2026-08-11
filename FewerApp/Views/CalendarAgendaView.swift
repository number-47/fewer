import FewerCore
import SwiftUI

struct CalendarAgendaView: View {
    let events: [CalendarEventItem]
    let authorizationState: SystemCalendarAuthorizationState
    let reminderAuthorizationState: SystemCalendarAuthorizationState
    let isLoading: Bool
    let isRequestingAccess: Bool
    let errorMessage: String?
    let language: CalendarLanguage
    let requestAccess: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language.text(chinese: "日程与节假日", english: "Schedule & Holidays"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 112, alignment: .topLeading)
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
                message: language.text(
                    chinese: "允许读取系统日历和提醒事项后，可展示节假日、日程与计划任务。",
                    english: "Allow Calendar and Reminders access to show holidays, events, and planned tasks."
                ),
                buttonTitle: language.text(chinese: "允许访问", english: "Allow Access"),
                action: requestAccess
            )
        } else {
            permissionPrompt(
                message: language.text(
                    chinese: "需要系统日历或提醒事项的完整读取权限。",
                    english: "Full Calendar or Reminders read access is required."
                ),
                buttonTitle: language.text(chinese: "打开系统设置", english: "Open System Settings"),
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
                title: language.text(chinese: "显示计划事项", english: "Show Planned Tasks"),
                action: isRequestable(reminderAuthorizationState) ? requestAccess : openSettings
            )
        }
        if authorizationState != .fullAccess {
            return MissingAccessPrompt(
                title: language.text(chinese: "显示日历日程", english: "Show Calendar Events"),
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
            Text(language.text(chinese: "当天没有日程或节假日", english: "No events or holidays"))
                .font(.caption)
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

    private func eventRow(_ event: CalendarEventItem) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(color(for: event))
                .frame(width: 7, height: 7)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title.isEmpty
                     ? language.text(chinese: "无标题日程", english: "Untitled Event")
                     : event.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(timeText(for: event))
                    Text(event.calendarTitle)
                        .lineLimit(1)

                    if event.kind == .reminder {
                        Label(
                            event.isCompleted
                                ? language.text(chinese: "已完成", english: "Completed")
                                : language.text(chinese: "计划", english: "Planned"),
                            systemImage: event.isCompleted ? "checkmark.circle.fill" : "checklist"
                        )
                        .labelStyle(.titleAndIcon)
                    }

                    if event.isSubscription {
                        Label(
                            language.text(chinese: "订阅", english: "Subscription"),
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

    private func timeText(for event: CalendarEventItem) -> String {
        if event.isAllDay {
            return language.text(chinese: "全天", english: "All-day")
        }
        return event.startDate.formatted(
            .dateTime.hour().minute().locale(language.locale)
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
}

private struct MissingAccessPrompt {
    let title: String
    let action: () -> Void
}
