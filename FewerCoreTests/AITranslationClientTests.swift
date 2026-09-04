import Foundation
import XCTest
@testable import FewerCore

final class AITranslationClientTests: XCTestCase {
    func testValidatorAcceptsHTTPSRemoteEndpointWithAPIKey() throws {
        let credentials = try AITranslationConfigurationValidator.credentials(from: .init(
            endpoint: "https://api.example.com/v1/chat/completions",
            model: "model-a",
            apiKey: " key "
        ))

        XCTAssertEqual(credentials.configuration.endpoint.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(credentials.configuration.model, "model-a")
        XCTAssertEqual(credentials.apiKey, "key")
    }

    func testValidatorAllowsHTTPLoopbackWithoutAPIKey() throws {
        for endpoint in [
            "http://localhost:8080/v1/chat/completions",
            "http://127.0.0.1:8080/v1/chat/completions",
            "http://[::1]:8080/v1/chat/completions",
        ] {
            XCTAssertNoThrow(try AITranslationConfigurationValidator.credentials(from: .init(
                endpoint: endpoint,
                model: "local-model"
            )))
        }
    }

    func testValidatorRejectsRemoteHTTPAndMissingRemoteKey() throws {
        XCTAssertThrowsError(try AITranslationConfigurationValidator.credentials(from: .init(
            endpoint: "http://api.example.com/v1/chat/completions",
            model: "model-a",
            apiKey: "key"
        ))) {
            XCTAssertEqual($0 as? AITranslationConfigurationError, .unsupportedEndpoint)
        }
        XCTAssertThrowsError(try AITranslationConfigurationValidator.credentials(from: .init(
            endpoint: "https://api.example.com/v1/chat/completions",
            model: "model-a"
        ))) {
            XCTAssertEqual($0 as? AITranslationConfigurationError, .missingAPIKey)
        }
    }

    func testValidatorRequiresCompleteChatCompletionsEndpointAndModel() {
        XCTAssertThrowsError(try AITranslationConfigurationValidator.credentials(from: .init(
            endpoint: "https://api.example.com/v1",
            model: "model-a",
            apiKey: "key"
        ))) {
            XCTAssertEqual($0 as? AITranslationConfigurationError, .invalidEndpoint)
        }
        XCTAssertThrowsError(try AITranslationConfigurationValidator.credentials(from: .init(
            endpoint: "https://api.example.com/v1/chat/completions",
            model: " ",
            apiKey: "key"
        ))) {
            XCTAssertEqual($0 as? AITranslationConfigurationError, .missingModel)
        }
    }

    func testSettingsStorePersistsOnlyNonSensitiveConfigurationInDefaults() throws {
        let suiteName = "FewerCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secrets = InMemorySecretStore()
        let store = AITranslationSettingsStore(defaults: defaults, secretStore: secrets)
        let profile = AITranslationProfile(
            name: "远程服务",
            endpoint: "https://api.example.com/v1/chat/completions",
            model: "model-a"
        )

        try store.saveProfile(profile, apiKey: "super-secret")

        XCTAssertEqual(store.loadProfiles(), [profile])
        XCTAssertEqual(try store.loadCredentials(), try AITranslationConfigurationValidator.credentials(
            configuration: .init(endpoint: URL(string: profile.endpoint)!, model: profile.model),
            apiKey: "super-secret"
        ))
        XCTAssertEqual(try secrets.loadAPIKey(profileID: profile.id), "super-secret")
        XCTAssertFalse(
            String(data: defaults.data(forKey: AITranslationSettingsStore.profilesKey)!, encoding: .utf8)!.contains("super-secret")
        )

        try store.removeAPIKey(profileID: profile.id)
        XCTAssertNil(try secrets.loadAPIKey(profileID: profile.id))
        XCTAssertNil(try store.loadCredentials())
    }

    func testProfilesRoundTripPersistsListAndActiveID() {
        let suiteName = "FewerCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AITranslationSettingsStore(defaults: defaults, secretStore: InMemorySecretStore())
        let first = AITranslationProfile(name: "一", endpoint: "http://localhost:8080/v1/chat/completions", model: "a")
        let second = AITranslationProfile(name: "二", endpoint: "http://localhost:8081/v1/chat/completions", model: "b")

        store.saveProfiles([first, second], activeProfileID: second.id)

        XCTAssertEqual(store.loadProfiles(), [first, second])
        XCTAssertEqual(store.loadActiveProfileID(), second.id)
    }

    func testSaveProfilesIgnoresUnknownActiveProfileID() {
        let suiteName = "FewerCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AITranslationSettingsStore(defaults: defaults, secretStore: InMemorySecretStore())
        let profile = AITranslationProfile(name: "服务", endpoint: "", model: "")
        let unknownID = UUID()

        store.saveProfiles([profile], activeProfileID: unknownID)

        XCTAssertNil(store.loadActiveProfileID())
        XCTAssertEqual(store.loadProfiles(), [profile])
    }

    func testLegacyConfigurationMigratesToSingleProfileWithKeychainKey() throws {
        let suiteName = "FewerCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secrets = InMemorySecretStore()
        let store = AITranslationSettingsStore(defaults: defaults, secretStore: secrets)
        let legacy = try AITranslationConfigurationValidator.credentials(from: .init(
            endpoint: "https://api.example.com/v1/chat/completions",
            model: "model-a",
            apiKey: "legacy-key"
        ))
        defaults.set(try JSONEncoder().encode(legacy.configuration), forKey: AITranslationSettingsStore.configurationKey)
        try secrets.saveLegacyAPIKey("legacy-key")

        let profiles = store.loadProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.name, AITranslationSettingsStore.legacyProfileName)
        XCTAssertEqual(profiles.first?.endpoint, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(store.loadActiveProfileID(), profiles.first?.id)
        XCTAssertEqual(try store.loadCredentials(), legacy)
        // 旧 account 密钥已迁到 per-profile account 并清理。
        XCTAssertEqual(try secrets.loadAPIKey(profileID: profiles.first!.id), "legacy-key")
        XCTAssertNil(try secrets.loadLegacyAPIKey())
    }

    func testLoadCredentialsFallsBackToFirstProfileWhenActiveIDMissing() throws {
        let suiteName = "FewerCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secrets = InMemorySecretStore()
        let store = AITranslationSettingsStore(defaults: defaults, secretStore: secrets)
        let profile = AITranslationProfile(
            name: "本机服务",
            endpoint: "http://localhost:8080/v1/chat/completions",
            model: "local-model"
        )
        store.saveProfiles([profile], activeProfileID: nil)

        let credentials = try store.loadCredentials()
        XCTAssertEqual(credentials?.configuration.endpoint.absoluteString, profile.endpoint)
        XCTAssertEqual(credentials?.apiKey, "")
    }

    func testLoadCredentialsReturnsNilForIncompleteOrKeylessRemoteProfile() throws {
        let suiteName = "FewerCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AITranslationSettingsStore(defaults: defaults, secretStore: InMemorySecretStore())
        let incomplete = AITranslationProfile(name: "未配置", endpoint: "", model: "")
        let remoteKeyless = AITranslationProfile(
            name: "远程未带密钥",
            endpoint: "https://api.example.com/v1/chat/completions",
            model: "model-a"
        )
        store.saveProfiles([incomplete, remoteKeyless], activeProfileID: remoteKeyless.id)

        XCTAssertNil(try store.credentials(for: incomplete.id))
        XCTAssertNil(try store.credentials(for: remoteKeyless.id))
        XCTAssertNil(try store.loadCredentials())
    }

    func testSecretKeysAreIsolatedPerProfile() throws {
        let secrets = InMemorySecretStore()
        let first = UUID()
        let second = UUID()

        try secrets.saveAPIKey("key-one", profileID: first)
        try secrets.saveAPIKey("key-two", profileID: second)

        XCTAssertEqual(try secrets.loadAPIKey(profileID: first), "key-one")
        XCTAssertEqual(try secrets.loadAPIKey(profileID: second), "key-two")
        try secrets.removeAPIKey(profileID: first)
        XCTAssertNil(try secrets.loadAPIKey(profileID: first))
        XCTAssertEqual(try secrets.loadAPIKey(profileID: second), "key-two")
    }

    func testConfigurationServiceSavesOnlyAfterConnectionTestSucceeds() async throws {
        let suiteName = "FewerCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secrets = InMemorySecretStore()
        let store = AITranslationSettingsStore(defaults: defaults, secretStore: secrets)
        let previous = try remoteCredentials()
        let previousProfile = AITranslationProfile(
            name: "原服务",
            endpoint: previous.configuration.endpoint.absoluteString,
            model: previous.configuration.model
        )
        try store.saveProfile(previousProfile, apiKey: previous.apiKey)
        let failingService = AITranslationConfigurationService(
            client: AITranslationClient(transport: FailingTransport(error: URLError(.cannotConnectToHost))),
            store: store
        )
        let replacement = AITranslationProfile(
            name: "新服务",
            endpoint: "https://new.example.com/v1/chat/completions",
            model: "model-b"
        )

        do {
            try await failingService.testAndSave(replacement, apiKey: "new-key")
            XCTFail("Expected connection test to fail")
        } catch {
            XCTAssertEqual(error as? AITranslationError, .networkFailure)
        }
        XCTAssertEqual(try store.loadCredentials(), previous)
        XCTAssertEqual(store.loadProfiles().first?.endpoint, previousProfile.endpoint)

        let successfulService = AITranslationConfigurationService(
            client: AITranslationClient(transport: CapturingTransport(response: successResponse())),
            store: store
        )
        try await successfulService.testAndSave(replacement, apiKey: "new-key")

        XCTAssertEqual(try store.credentials(for: replacement.id), try AITranslationConfigurationValidator.credentials(
            configuration: .init(endpoint: URL(string: replacement.endpoint)!, model: replacement.model),
            apiKey: "new-key"
        ))
    }

    func testClientBuildsTextOnlyChatCompletionsRequestAndParsesTranslation() async throws {
        let transport = CapturingTransport(response: .init(
            data: Data(#"{"choices":[{"message":{"content":"译文\n保留换行"}}]}"#.utf8),
            statusCode: 200
        ))
        let client = AITranslationClient(transport: transport)
        let translation = try await client.translate(
            sourceText: "Hello\nworld",
            sourceLanguageCode: nil,
            targetLanguageCode: "zh-Hans",
            credentials: try remoteCredentials()
        )

        XCTAssertEqual(translation, "译文\n保留换行")
        let request = try XCTUnwrap(transport.request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "model-a")
        XCTAssertEqual(json["stream"] as? Bool, false)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"], "user")
        XCTAssertEqual(
            messages[0]["content"],
            "\(AITranslationClient.systemInstruction)\nSource language: auto\nTarget language: zh-Hans\nOCR text:\nHello\nworld"
        )
        XCTAssertFalse(String(data: body, encoding: .utf8)!.contains("image"))
        XCTAssertFalse(String(data: body, encoding: .utf8)!.contains("coordinates"))
    }

    func testClientBuildsTranslateGemmaStructuredContentRequest() async throws {
        let transport = CapturingTransport(response: successResponse())
        let client = AITranslationClient(transport: transport)
        let credentials = try AITranslationConfigurationValidator.credentials(from: .init(
            endpoint: "http://127.0.0.1:8000/v1/chat/completions",
            model: "TranslateGemma-12b-it-6bit"
        ))

        _ = try await client.translate(
            sourceText: "Mac 本地接入 AI 翻译速度比较慢，应该怎么优化？",
            sourceLanguageCode: "zh",
            targetLanguageCode: "en-US",
            credentials: credentials
        )

        let body = try XCTUnwrap(transport.request?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "TranslateGemma-12b-it-6bit")
        XCTAssertEqual(json["stream"] as? Bool, false)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: String]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"], "text")
        XCTAssertEqual(content[0]["source_lang_code"], "zh")
        XCTAssertEqual(content[0]["target_lang_code"], "en-US")
        XCTAssertEqual(content[0]["text"], "Mac 本地接入 AI 翻译速度比较慢，应该怎么优化？")
        XCTAssertFalse(String(data: body, encoding: .utf8)!.contains(AITranslationClient.systemInstruction))
    }

    func testClientOmitsAuthorizationForLocalEmptyKey() async throws {
        let transport = CapturingTransport(response: successResponse())
        let client = AITranslationClient(transport: transport)
        let credentials = try AITranslationConfigurationValidator.credentials(from: .init(
            endpoint: "http://localhost:8080/v1/chat/completions",
            model: "local-model"
        ))

        _ = try await client.translate(
            sourceText: "hello",
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-Hans",
            credentials: credentials
        )

        XCTAssertNil(transport.request?.value(forHTTPHeaderField: "Authorization"))
    }

    func testClientMapsHTTPAndTransportFailures() async throws {
        let cases: [(AITranslationHTTPResponse, AITranslationError)] = [
            (.init(data: Data(), statusCode: 401), .authenticationFailed),
            (.init(data: Data(), statusCode: 403), .authenticationFailed),
            (.init(data: Data(), statusCode: 429), .rateLimited),
            (.init(data: Data(), statusCode: 503), .serverFailure(503)),
            (.init(data: Data("{}".utf8), statusCode: 200), .invalidResponse),
        ]
        for (response, expected) in cases {
            await assertClientError(expected, transport: CapturingTransport(response: response))
        }
        await assertClientError(.timedOut, transport: FailingTransport(error: URLError(.timedOut)))
        await assertClientError(.networkFailure, transport: FailingTransport(error: URLError(.notConnectedToInternet)))
        await assertClientError(.cancelled, transport: FailingTransport(error: CancellationError()))
    }

    func testEphemeralTransportConfigurationHasNoPersistentCookiesCacheOrCredentials() {
        let configuration = URLSessionAITranslationTransport.ephemeralConfiguration()

        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 30)
    }

    private func remoteCredentials() throws -> AITranslationCredentials {
        try AITranslationConfigurationValidator.credentials(from: .init(
            endpoint: "https://api.example.com/v1/chat/completions",
            model: "model-a",
            apiKey: "test-key"
        ))
    }

    private func successResponse() -> AITranslationHTTPResponse {
        .init(data: Data(#"{"choices":[{"message":{"content":"译文"}}]}"#.utf8), statusCode: 200)
    }

    private func assertClientError(
        _ expected: AITranslationError,
        transport: any AITranslationTransport
    ) async {
        do {
            _ = try await AITranslationClient(transport: transport).translate(
                sourceText: "hello",
                sourceLanguageCode: "en",
                targetLanguageCode: "zh-Hans",
                credentials: try! remoteCredentials()
            )
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? AITranslationError, expected)
        }
    }
}

private final class InMemorySecretStore: AITranslationSecretStoring, @unchecked Sendable {
    private var values: [UUID: String] = [:]
    private var legacyValue: String?

    func loadAPIKey(profileID: UUID) throws -> String? { values[profileID] }
    func saveAPIKey(_ apiKey: String, profileID: UUID) throws { values[profileID] = apiKey }
    func removeAPIKey(profileID: UUID) throws { values[profileID] = nil }
    func loadLegacyAPIKey() throws -> String? { legacyValue }
    func removeLegacyAPIKey() throws { legacyValue = nil }

    /// 供迁移测试写入旧版 account。
    func saveLegacyAPIKey(_ apiKey: String) throws { legacyValue = apiKey }
}

private final class CapturingTransport: AITranslationTransport, @unchecked Sendable {
    private(set) var request: URLRequest?
    private let response: AITranslationHTTPResponse

    init(response: AITranslationHTTPResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> AITranslationHTTPResponse {
        self.request = request
        return response
    }
}

private final class FailingTransport: AITranslationTransport, @unchecked Sendable {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func send(_: URLRequest) async throws -> AITranslationHTTPResponse {
        throw error
    }
}
