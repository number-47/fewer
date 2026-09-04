import AppKit
import FewerCore
import SwiftUI

/// AI 翻译设置：多服务配置与密钥管理。输入框经系统编辑菜单支持 Cmd+V 粘贴。
struct AITranslationSettingsView: View {
    @State private var profiles: [AITranslationProfile] = []
    @State private var activeProfileID: UUID?
    @State private var selectedProfileID: UUID?
    @State private var name = ""
    @State private var endpoint = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var hasSavedAPIKey = false
    @State private var isTesting = false
    @State private var message: String?
    @State private var showsRemoveConfirmation = false
    private let store = AITranslationSettingsStore()
    private let configurationService = AITranslationConfigurationService()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                FewerSettingsCard {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 翻译")
                            .fontWeight(.semibold)
                        Text("启用后，只有你在截图翻译结果中切换到 AI 时，Fewer 才会向你配置的服务发送 OCR 文本、原文语言和目标语言；不会发送截图、文字坐标或其他屏幕信息。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
                FewerSettingsCard {
                    HStack(alignment: .top, spacing: 0) {
                        profileList
                            .frame(width: 220, alignment: .leading)
                        Divider()
                        editorCard
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 16)
                    }
                    .padding(16)
                }
            }
            .padding(.bottom, 24)
        }
        .onAppear(perform: reload)
        .onDisappear { apiKey = "" }
        .alert("删除服务配置？", isPresented: $showsRemoveConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                removeProfile()
            }
        } message: {
            Text("将删除该服务配置和保存在钥匙串中的 API 密钥。")
        }
    }

    private var privacyText: String {
        "启用后，只有你在截图翻译结果中切换到 AI 时，Fewer 才会向你配置的服务发送 OCR 文本、原文语言和目标语言；不会发送截图、文字坐标或其他屏幕信息。"
    }

    // MARK: - 配置列表

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(profiles) { profile in
                Button {
                    selectedProfileID = profile.id
                    loadSelection()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(profile.name.isEmpty ? "未命名服务" : profile.name)
                                    .lineLimit(1)
                                if profile.id == activeProfileID {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .help("当前使用")
                                }
                            }
                            Text(profile.model)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .background(
                        selectedProfileID == profile.id
                            ? Color(red: 0, green: 113 / 255, blue: 227 / 255).opacity(0.12)
                            : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button {
                    addProfile()
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加服务配置")
                Button(role: .destructive) {
                    showsRemoveConfirmation = true
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedProfileID == nil)
                .help("删除选中的服务配置")
                Spacer()
            }
        }
    }

    // MARK: - 编辑区

    @ViewBuilder
    private var editorCard: some View {
        if selectedProfileID == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("尚未选择服务配置")
                    .foregroundStyle(.secondary)
                Text("点击左侧 + 添加一个 OpenAI-compatible 服务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                inputRow("名称", placeholder: "服务名称", text: $name)
                inputRow("服务地址", placeholder: "完整 Chat Completions 地址", text: $endpoint)
                inputRow("模型", placeholder: "模型", text: $model)
                inputRow("API 密钥", placeholder: "API 密钥（本机服务可留空）", text: $apiKey, secure: true)
                HStack(spacing: 12) {
                    Image(systemName: hasSavedAPIKey ? "key.fill" : "key")
                        .font(.caption)
                        .foregroundStyle(hasSavedAPIKey ? .green : .secondary)
                    Text(hasSavedAPIKey ? "钥匙串中已保存密钥" : "未保存密钥")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button(isTesting ? "正在测试连接…" : "保存并测试连接") {
                        saveAndTest()
                    }
                    .disabled(isTesting)
                    Button("设为当前") {
                        setAsActive()
                    }
                    .disabled(isTesting || selectedProfileID == activeProfileID)
                    Button("删除密钥", role: .destructive) {
                        removeAPIKey()
                    }
                    .disabled(isTesting || !hasSavedAPIKey)
                    Spacer()
                }
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func inputRow(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        secure: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if secure {
                    SecureField(placeholder, text: text)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField(placeholder, text: text)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    // MARK: - 行为

    private func reload() {
        profiles = store.loadProfiles()
        activeProfileID = store.loadActiveProfileID() ?? profiles.first?.id
        if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = activeProfileID ?? profiles.first?.id
        }
        loadSelection()
    }

    private func loadSelection() {
        guard let id = selectedProfileID,
              let profile = profiles.first(where: { $0.id == id })
        else {
            name = ""
            endpoint = ""
            model = ""
            apiKey = ""
            hasSavedAPIKey = false
            message = nil
            return
        }
        // 密钥不可回读明文；SecureField 保持空白，保存远程服务时需重新输入。
        name = profile.name
        endpoint = profile.endpoint
        model = profile.model
        apiKey = ""
        hasSavedAPIKey = store.hasAPIKey(profileID: id)
        message = nil
    }

    private func addProfile() {
        let profile = AITranslationProfile(name: "新服务", endpoint: "", model: "")
        profiles.append(profile)
        store.saveProfiles(profiles, activeProfileID: activeProfileID)
        selectedProfileID = profile.id
        loadSelection()
    }

    private func removeProfile() {
        guard let id = selectedProfileID,
              let index = profiles.firstIndex(where: { $0.id == id })
        else { return }
        try? store.removeAPIKey(profileID: id)
        profiles.remove(at: index)
        store.saveProfiles(profiles, activeProfileID: activeProfileID == id ? nil : activeProfileID)
        reload()
    }

    private func setAsActive() {
        guard let id = selectedProfileID else { return }
        activeProfileID = id
        store.saveProfiles(profiles, activeProfileID: id)
    }

    private func saveAndTest() {
        guard let id = selectedProfileID else { return }
        let profile = AITranslationProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: endpoint,
            model: model
        )
        isTesting = true
        message = nil
        Task {
            do {
                try await configurationService.testAndSave(profile, apiKey: apiKey)
                guard !Task.isCancelled else { return }
                profiles = store.loadProfiles()
                activeProfileID = store.loadActiveProfileID() ?? activeProfileID
                apiKey = ""
                hasSavedAPIKey = store.hasAPIKey(profileID: id)
                message = "AI 翻译服务已保存。"
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            isTesting = false
        }
    }

    private func removeAPIKey() {
        guard let id = selectedProfileID else { return }
        isTesting = true
        message = nil
        Task {
            do {
                try await configurationService.removeAPIKey(profileID: id)
                guard !Task.isCancelled else { return }
                hasSavedAPIKey = false
                apiKey = ""
                message = "已删除钥匙串中的 API 密钥。"
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            isTesting = false
        }
    }
}
