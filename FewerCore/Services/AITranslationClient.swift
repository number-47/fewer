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
    func load() throws -> String?
    func save(_ apiKey: String) throws
    func remove() throws
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

/// 只保存 API 密钥；endpoint 和 model 由 `AITranslationSettingsStore` 写入 UserDefaults。
public final class KeychainAITranslationSecretStore: AITranslationSecretStoring, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "com.number47.fewer.ai-translation",
        account: String = "api-key"
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(returnData: true) as CFDictionary, &result)
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

    public func save(_ apiKey: String) throws {
        let data = Data(apiKey.utf8)
        let status = SecItemUpdate(
            query(returnData: false) as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw AITranslationSecretStoreError.keychain(status)
        }

        var attributes = query(returnData: false)
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AITranslationSecretStoreError.keychain(addStatus)
        }
    }

    public func remove() throws {
        let status = SecItemDelete(query(returnData: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AITranslationSecretStoreError.keychain(status)
        }
    }

    private func query(returnData: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if returnData {
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
        }
        return query
    }
}

/// 配置和密钥的唯一写入口。密钥写入成功前不会替换 UserDefaults 中的有效配置。
public final class AITranslationSettingsStore: @unchecked Sendable {
    public static let configurationKey = "fewer.aiTranslation.configuration"

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

    public func loadConfiguration() -> AITranslationConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return decodedConfiguration()
    }

    public func loadCredentials() throws -> AITranslationCredentials? {
        lock.lock()
        defer { lock.unlock() }
        guard let configuration = decodedConfiguration() else { return nil }
        return try AITranslationConfigurationValidator.credentials(
            configuration: configuration,
            apiKey: secretStore.load() ?? ""
        )
    }

    public func save(_ credentials: AITranslationCredentials) throws {
        let validated = try AITranslationConfigurationValidator.credentials(
            configuration: credentials.configuration,
            apiKey: credentials.apiKey
        )
        let data = try encoder.encode(validated.configuration)

        lock.lock()
        defer { lock.unlock() }
        if validated.apiKey.isEmpty {
            try secretStore.remove()
        } else {
            try secretStore.save(validated.apiKey)
        }
        defaults.set(data, forKey: Self.configurationKey)
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        try secretStore.remove()
        defaults.removeObject(forKey: Self.configurationKey)
    }

    private func decodedConfiguration() -> AITranslationConfiguration? {
        guard let data = defaults.data(forKey: Self.configurationKey) else { return nil }
        return try? decoder.decode(AITranslationConfiguration.self, from: data)
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
        let messageContent = """
        \(Self.systemInstruction)
        Source language: \(sourceLanguage?.isEmpty == false ? sourceLanguage! : "auto")
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

/// 供设置页执行“先测试、后保存”的单一入口。
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

    public func test(_ draft: AITranslationConfigurationDraft) async throws {
        try await client.testConnection(try AITranslationConfigurationValidator.credentials(from: draft))
    }

    public func testAndSave(_ draft: AITranslationConfigurationDraft) async throws {
        let credentials = try AITranslationConfigurationValidator.credentials(from: draft)
        try await client.testConnection(credentials)
        try store.save(credentials)
    }

    public func clear() throws {
        try store.clear()
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

private struct ChatCompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}
