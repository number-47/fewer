import FewerCore
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject private var presentationController = AppPresentationController.shared
    @AppStorage(CalendarLanguage.storageKey) private var calendarLanguageValue = CalendarLanguage.chinese.rawValue

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                FewerSettingsCard {
                    FewerSettingsRow {
                        VStack(alignment: .leading, spacing: 2) { Text("显示位置"); Text("应用以菜单栏模式或 Dock 模式运行").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Picker("", selection: presentationModeBinding) {
                    ForEach(AppPresentationMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 180)
                    }
                    Divider()
                    FewerSettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("日历语言")
                            Text("设置月份和星期的显示语言").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: calendarLanguageBinding) {
                            ForEach(CalendarLanguage.allCases) { language in
                                Text(language.title).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                        .accessibilityIdentifier("settings.calendarLanguage")
                    }
                    Divider()
                    FewerSettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("重名处理")
                            Text("截图文件名冲突时的处理方式").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { model.settings.conflictPolicy },
                            set: { model.setConflictPolicy($0) }
                        )) {
                            Text("添加序号").tag(ConflictPolicy.keepBoth)
                            Text("跳过").tag(ConflictPolicy.skip)
                            Text("替换").tag(ConflictPolicy.replace)
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    Divider()
                    FewerSettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("通知")
                            Text("截图完成、操作完成等通知").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { model.settings.notificationsEnabled }, set: { model.setNotificationsEnabled($0) })).labelsHidden()
                    }
                    Divider()
                    FewerSettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("登录时启动助手")
                            Text("FewerShortcutHelper 开机自启动").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { model.settings.launchHelperAtLogin }, set: { model.setLaunchHelperAtLogin($0) })).labelsHidden()
                    }
                }
            }.padding(.bottom, 24)
        }
    }

    private var presentationModeBinding: Binding<AppPresentationMode> {
        Binding(
            get: { presentationController.mode },
            set: { mode in
                presentationController.setMode(mode)
            }
        )
    }

    private var calendarLanguageBinding: Binding<CalendarLanguage> {
        Binding(
            get: { CalendarLanguage(rawValue: calendarLanguageValue) ?? .chinese },
            set: { calendarLanguageValue = $0.rawValue }
        )
    }
}
