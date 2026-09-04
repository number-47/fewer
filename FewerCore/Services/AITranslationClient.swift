import Foundation
import Security

public enum OCRTranslationProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case ai

    public var id: String { rawValue }
}

/// 可以安全持久化的 AI 翻译服务配置；API 密钥始终单独保存在 Keychain。
public struct AITranslationConfiguration: Codable, Equatable, Sendable {
    public let endpoint: URL
    public let model: String

    public init(endpoint: URL, model: String) {
        self.endpoint = endpoint
        self.model = model
    }
}

/// 一条可安全持久化的 OpenAI-compatible 服务配置；endpoint/model 存 UserDefaults，密钥按 profile 存 Keychain。
public struct AITranslationProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var endpoint: String
    public var model: String

    public init(id: UUID = UUID(), name: String, endpoint: String, model: String) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.model = model
    }
}

/// 设置页编辑期间使用的临时值。它不得被直接持久化。
public struct AITranslationConfigurationDraft: Equatable, Sendable {
    public var endpoint: String
    public var model: String
    public var apiKey: String

    public init(endpoint: String = "", model: String = "", apiKey: String = "") {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
    }
}

public struct AITranslationCredentials: Equatable, Sendable {
    public let configuration: AITranslationConfiguration
    public let apiKey: String

    public init(configuration: AITranslationConfiguration, apiKey: String) {
        self.configuration = configuration
        self.apiKey = apiKey
    }
}

public enum AITranslationConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case unsupportedEndpoint
    case missingModel
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "请输入完整的 Chat Completions 地址。"
        case .unsupportedEndpoint:
            "公网服务仅支持 HTTPS；HTTP 仅可用于 localhost、127.0.0.1 或 ::1。"
        case .missingModel:
            "请输入模型名称。"
        case .missingAPIKey:
            "公网服务需要 API 密钥。"
        }
    }
}

public enum AITranslationConfigurationValidator {
    public static func credentials(
        from draft: AITranslationConfigurationDraft
    ) throws -> AITranslationCredentials {
        let endpointText = draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: endpointText) else {
            throw AITranslationConfigurationError.invalidEndpoint
        }
        let configuration = AITranslationConfiguration(
            endpoint: endpoint,
            model: draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return try credentials(configuration: configuration, apiKey: draft.apiKey)
    }

    public static func credentials(
        configuration: AITranslationConfiguration,
        apiKey: String
    ) throws -> AITranslationCredentials {
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AITranslationConfigurationError.missingModel
        }
        guard let scheme = configuration.endpoint.scheme?.lowercased(),
              let host = configuration.endpoint.host?.lowercased(),
              configuration.endpoint.user == nil,
              configuration.endpoint.password == nil,
              configuration.endpoint.fragment == nil,
              configuration.endpoint.path.lowercased().hasSuffix("/chat/completions")
        else {
            throw AITranslationConfigurationError.invalidEndpoint
        }

        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        switch scheme {
        case "https":
            break
        case "http" where isLoopback:
            break
        default:
            throw AITranslationConfigurationError.unsupportedEndpoint
        }

        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLoopback || !normalizedKey.isEmpty else {
            throw AITranslationConfigurationError.missingAPIKey
        }
        return AITranslationCredentials(configuration: configuration, apiKey: normalizedKey)
    }
}

public protocol AITranslationSecretStoring: Sendable {
    func loadAPIKey(profileID: UUID) throws -> String?
    func saveAPIKey(_ apiKey: String, profileID: UUID) throws
    func removeAPIKey(profileID: UUID) throws
    /// 读取旧版固定 account 中的密钥，供一次性迁移。
    func loadLegacyAPIKey() throws -> String?
    /// 删除旧版固定 account 中的密钥。
    func removeLegacyAPIKey() throws
}

public enum AITranslationSecretStoreError: Error, Equatable, LocalizedError, Sendable {
    case keychain(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .keychain:
            "无法访问 AI 翻译密钥。"
        case .invalidData:
            "AI 翻译密钥格式无效。"
        }
    }
}

/// 只保存 API 密钥；account 为 profile id 的 uuidString，endpoint 和 model 由 `AITranslationSettingsStore` 写入 UserDefaults。
public final class KeychainAITranslationSecretStore: AITranslationSecretStoring, @unchecked Sendable {
    private let service: String
    private let legacyAccount: String

    public init(
        service: String = "com.number47.fewer.ai-translation",
        legacyAccount: String = "api-key"
    ) {
        self.service = service
        self.legacyAccount = legacyAccount
    }

    public func loadAPIKey(profileID: UUID) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(profileID: profileID, returnData: true) as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let apiKey = String(data: data, encoding: .utf8)
            else { throw AITranslationSecretStoreError.invalidData }
            return apiKey
        case errSecItemNotFound:
            return nil
        default:
            throw AITranslationSecretStoreError.keychain(status)
        }
    }

    public func saveAPIKey(_ apiKey: String, profileID: UUID) throws {
        let data = Data(apiKey.utf8)
        let status = SecItemUpdate(
            query(profileID: profileID, returnData: false) as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw AITranslationSecretStoreError.keychain(status)
        }

        var attributes = query(profileID: profileID, returnData: false)
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AITranslationSecretStoreError.keychain(addStatus)
        }
    }

    public func removeAPIKey(profileID: UUID) throws {
        let status = SecItemDelete(query(profileID: profileID, returnData: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AITranslationSecretStoreError.keychain(status)
        }
    }

    public func loadLegacyAPIKey() throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(legacyQuery(returnData: true) as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let apiKey = String(data: data, encoding: .utf8)
            else { throw AITranslationSecretStoreError.invalidData }
            return apiKey
        case errSecItemNotFound:
            return nil
        default:
            throw AITranslationSecretStoreError.keychain(status)
        }
    }

    public func removeLegacyAPIKey() throws {
        let status = SecItemDelete(legacyQuery(returnData: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AITranslationSecretStoreError.keychain(status)
        }
    }

    private func query(profileID: UUID, returnData: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileID.uuidString,
        ]
        if returnData {
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
        }
        return query
    }

    private func legacyQuery(returnData: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: legacyAccount,
        ]
        if returnData {
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
        }
        return query
    }
}

/// 配置和密钥的唯一写入口。密钥写入成功前不会替换 UserDefaults 中的有效配置；
/// 旧版单配置在首次读取时迁移为单 profile。
public final class AITranslationSettingsStore: @unchecked Sendable {
    /// 旧版单配置键；仅作迁移源，新写入一律用 profilesKey/activeProfileIDKey。
    public static let configurationKey = "fewer.aiTranslation.configuration"
    public static let profilesKey = "fewer.aiTranslation.profiles"
    public static let activeProfileIDKey = "fewer.aiTranslation.activeProfileID"
    public static let legacyProfileName = "默认服务"

    private let defaults: UserDefaults
    private let secretStore: any AITranslationSecretStoring
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        secretStore: any AITranslationSecretStoring = KeychainAITranslationSecretStore()
    ) {
        self.defaults = defaults
        self.secretStore = secretStore
    }

    /// 读取全部配置；首次调用时将旧版单配置迁移为单 profile（含密钥迁移）。
    public func loadProfiles() -> [AITranslationProfile] {
        lock.lock()
        defer { lock.unlock() }
        return migratedProfiles()
    }

    public func loadActiveProfileID() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return activeProfileIDLocked()
    }

    /// 落盘配置列表；不在列表中的 activeProfileID 被置 nil（读取时回退到第一个）。
    public func saveProfiles(_ profiles: [AITranslationProfile], activeProfileID: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        persistProfiles(profiles, activeProfileID: activeProfileID)
    }

    /// 校验并保存单条配置；密钥写入成功后才替换 UserDefaults 中的配置。
    public func saveProfile(_ profile: AITranslationProfile, apiKey: String) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let validated = try AITranslationConfigurationValidator.credentials(
            configuration: AITranslationConfiguration(endpoint: endpointURL(profile.endpoint), model: profile.model),
            apiKey: trimmedKey
        )

        lock.lock()
        defer { lock.unlock() }
        var profiles = migratedProfiles()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        if validated.apiKey.isEmpty {
            try secretStore.removeAPIKey(profileID: profile.id)
        } else {
            try secretStore.saveAPIKey(validated.apiKey, profileID: profile.id)
        }
        persistProfiles(profiles, activeProfileID: activeProfileIDLocked())
    }

    public func hasAPIKey(profileID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (try? secretStore.loadAPIKey(profileID: profileID))?.isEmpty == false
    }

    public func removeAPIKey(profileID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try secretStore.removeAPIKey(profileID: profileID)
    }

    /// 读取指定配置的密钥；endpoint/model 不完整或密钥不满足规则时返回 nil（未配置态）。
    public func credentials(for profileID: UUID) throws -> AITranslationCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return credentialsLocked(profileID: profileID)
    }

    /// 读取当前使用配置的密钥；无 activeProfileID 时回退到第一个。
    public func loadCredentials() throws -> AITranslationCredentials? {
        lock.lock()
        defer { lock.unlock() }
        let profiles = migratedProfiles()
        let activeID = activeProfileIDLocked() ?? profiles.first?.id
        guard let activeID else { return nil }
        return credentialsLocked(profileID: activeID, profiles: profiles)
    }

    // MARK: - 内部（调用方需已持锁）

    private func migratedProfiles() -> [AITranslationProfile] {
        if let data = defaults.data(forKey: Self.profilesKey),
           let profiles = try? decoder.decode([AITranslationProfile].self, from: data) {
            return profiles
        }

        var profiles: [AITranslationProfile] = []
        if let data = defaults.data(forKey: Self.configurationKey),
           let configuration = try? decoder.decode(AITranslationConfiguration.self, from: data) {
            let profile = AITranslationProfile(
                name: Self.legacyProfileName,
                endpoint: configuration.endpoint.absoluteString,
                model: configuration.model
            )
            if let legacyKey = try? secretStore.loadLegacyAPIKey(), !legacyKey.isEmpty {
                try? secretStore.saveAPIKey(legacyKey, profileID: profile.id)
                try? secretStore.removeLegacyAPIKey()
            }
            profiles = [profile]
        }
        persistProfiles(profiles, activeProfileID: profiles.first?.id)
        return profiles
    }

    private func persistProfiles(_ profiles: [AITranslationProfile], activeProfileID: UUID?) {
        guard let data = try? encoder.encode(profiles) else { return }
        defaults.set(data, forKey: Self.profilesKey)
        let validID = profiles.contains { $0.id == activeProfileID } ? activeProfileID : nil
        if let validID {
            defaults.set(validID.uuidString, forKey: Self.activeProfileIDKey)
        } else {
            defaults.removeObject(forKey: Self.activeProfileIDKey)
        }
    }

    private func activeProfileIDLocked() -> UUID? {
        guard let string = defaults.string(forKey: Self.activeProfileIDKey) else { return nil }
        return UUID(uuidString: string)
    }

    private func credentialsLocked(profileID: UUID, profiles: [AITranslationProfile]? = nil) -> AITranslationCredentials? {
        let knownProfiles = profiles ?? migratedProfiles()
        guard let profile = knownProfiles.first(where: { $0.id == profileID }) else { return nil }
        let configuration = AITranslationConfiguration(
            endpoint: endpointURL(profile.endpoint),
            model: profile.model
        )
        let apiKey = (try? secretStore.loadAPIKey(profileID: profileID)) ?? ""
        guard let credentials = try? AITranslationConfigurationValidator.credentials(
            configuration: configuration,
            apiKey: apiKey
        ) else { return nil }
        return credentials
    }

    private func endpointURL(_ endpoint: String) -> URL {
        URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(fileURLWithPath: "")
    }
}

public struct AITranslationHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol AITranslationTransport: Sendable {
    func send(_ request: URLRequest) async throws -> AITranslationHTTPResponse
}

public final class URLSessionAITranslationTransport: AITranslationTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: URLSessionAITranslationTransport.ephemeralConfiguration())) {
        self.session = session
    }

    public static func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return configuration
    }

    public func send(_ request: URLRequest) async throws -> AITranslationHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AITranslationError.invalidResponse
        }
        return AITranslationHTTPResponse(data: data, statusCode: response.statusCode)
    }
}

public enum AITranslationError: Error, Equatable, LocalizedError, Sendable {
    case emptySourceText
    case invalidConfiguration(AITranslationConfigurationError)
    case authenticationFailed
    case rateLimited
    case timedOut
    case networkFailure
    case serverFailure(Int)
    case invalidResponse
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptySourceText:
            "没有可翻译的文字。"
        case let .invalidConfiguration(error):
            error.errorDescription
        case .authenticationFailed:
            "AI 翻译服务拒绝了 API 密钥。"
        case .rateLimited:
            "AI 翻译服务请求过于频繁，请稍后重试。"
        case .timedOut:
            "AI 翻译服务请求超时。"
        case .networkFailure:
            "无法连接到 AI 翻译服务。"
        case .serverFailure:
            "AI 翻译服务暂时不可用。"
        case .invalidResponse:
            "AI 翻译服务返回了无法识别的结果。"
        case .cancelled:
            "AI 翻译已取消。"
        }
    }
}

public struct AITranslationClient: Sendable {
    public static let systemInstruction = "Translate the supplied OCR text. Return only the translation. Preserve paragraph breaks, line breaks, and punctuation."

    private let transport: any AITranslationTransport

    public init(transport: any AITranslationTransport = URLSessionAITranslationTransport()) {
        self.transport = transport
    }

    public func translate(
        sourceText: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        credentials: AITranslationCredentials
    ) async throws -> String {
        guard !sourceText.isEmpty else { throw AITranslationError.emptySourceText }
        do {
            let validated = try AITranslationConfigurationValidator.credentials(
                configuration: credentials.configuration,
                apiKey: credentials.apiKey
            )
            var request = try makeRequest(
                sourceText: sourceText,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode,
                credentials: validated
            )
            request.timeoutInterval = 30
            let response = try await transport.send(request)
            return try parse(response)
        } catch let error as AITranslationConfigurationError {
            throw AITranslationError.invalidConfiguration(error)
        } catch let error as AITranslationError {
            throw error
        } catch is CancellationError {
            throw AITranslationError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw AITranslationError.timedOut
            case .cancelled:
                throw AITranslationError.cancelled
            default:
                throw AITranslationError.networkFailure
            }
        } catch {
            throw AITranslationError.networkFailure
        }
    }

    public func testConnection(_ credentials: AITranslationCredentials) async throws {
        _ = try await translate(
            sourceText: "Connection test",
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-Hans",
            credentials: credentials
        )
    }

    private func makeRequest(
        sourceText: String,
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        credentials: AITranslationCredentials
    ) throws -> URLRequest {
        var request = URLRequest(url: credentials.configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !credentials.apiKey.isEmpty {
            request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let sourceLanguage = sourceLanguageCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceLanguageCode = sourceLanguage?.isEmpty == false ? sourceLanguage! : "auto"
        if credentials.configuration.model.lowercased().contains("translategemma") {
            request.httpBody = try JSONEncoder().encode(TranslateGemmaChatCompletionsRequest(
                model: credentials.configuration.model,
                stream: false,
                messages: [.init(
                    role: "user",
                    content: [.init(
                        type: "text",
                        sourceLanguageCode: sourceLanguageCode,
                        targetLanguageCode: targetLanguageCode,
                        text: sourceText
                    )]
                )]
            ))
        } else {
            let messageContent = """
            \(Self.systemInstruction)
            Source language: \(sourceLanguageCode)
            Target language: \(targetLanguageCode)
            OCR text:
            \(sourceText)
            """
            // 部分兼容服务的 chat 模板拒绝以 system 开头的对话，统一只用单条 user 消息。
            request.httpBody = try JSONEncoder().encode(ChatCompletionsRequest(
                model: credentials.configuration.model,
                stream: false,
                messages: [.init(role: "user", content: messageContent)]
            ))
        }
        return request
    }

    private func parse(_ response: AITranslationHTTPResponse) throws -> String {
        switch response.statusCode {
        case 200 ... 299:
            break
        case 401, 403:
            throw AITranslationError.authenticationFailed
        case 429:
            throw AITranslationError.rateLimited
        case 500 ... 599:
            throw AITranslationError.serverFailure(response.statusCode)
        default:
            throw AITranslationError.serverFailure(response.statusCode)
        }

        guard let payload = try? JSONDecoder().decode(ChatCompletionsResponse.self, from: response.data),
              let content = payload.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AITranslationError.invalidResponse
        }
        return content
    }
}

/// 供设置页执行“先测试、后保存”的单一入口，按 profile 写入。
public actor AITranslationConfigurationService {
    private let client: AITranslationClient
    private let store: AITranslationSettingsStore

    public init(
        client: AITranslationClient = AITranslationClient(),
        store: AITranslationSettingsStore = AITranslationSettingsStore()
    ) {
        self.client = client
        self.store = store
    }

    /// 仅测试草稿连通性，不落盘。
    public func test(_ draft: AITranslationConfigurationDraft) async throws {
        try await client.testConnection(try AITranslationConfigurationValidator.credentials(from: draft))
    }

    /// 测试该 profile 配置连通，成功后落盘 endpoint/model 与密钥。
    public func testAndSave(_ profile: AITranslationProfile, apiKey: String) async throws {
        let credentials = try AITranslationConfigurationValidator.credentials(
            configuration: AITranslationConfiguration(endpoint: endpointURL(profile.endpoint), model: profile.model),
            apiKey: apiKey
        )
        try await client.testConnection(credentials)
        try store.saveProfile(profile, apiKey: credentials.apiKey)
    }

    /// 删除该 profile 的 API 密钥。
    public func removeAPIKey(profileID: UUID) throws {
        try store.removeAPIKey(profileID: profileID)
    }

    private func endpointURL(_ endpoint: String) -> URL {
        URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(fileURLWithPath: "")
    }
}

private struct ChatCompletionsRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let stream: Bool
    let messages: [Message]
}

private struct TranslateGemmaChatCompletionsRequest: Encodable {
    struct Message: Encodable {
        struct Content: Encodable {
            let type: String
            let sourceLanguageCode: String
            let targetLanguageCode: String
            let text: String

            enum CodingKeys: String, CodingKey {
                case type
                case sourceLanguageCode = "source_lang_code"
                case targetLanguageCode = "target_lang_code"
                case text
            }
        }

        let role: String
        let content: [Content]
    }

    let model: String
    let stream: Bool
    let messages: [Message]
}

private struct ChatCompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}
