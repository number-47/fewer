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
        let credentials = try AITranslationConfigurationValidator.credentials(from: .init(
            endpoint: "https://api.example.com/v1/chat/completions",
            model: "model-a",
            apiKey: "super-secret"
        ))

        try store.save(credentials)

        XCTAssertEqual(try store.loadCredentials(), credentials)
        XCTAssertEqual(store.loadConfiguration(), credentials.configuration)
        XCTAssertEqual(try secrets.load(), "super-secret")
        XCTAssertFalse(String(data: defaults.data(forKey: AITranslationSettingsStore.configurationKey)!, encoding: .utf8)!.contains("super-secret"))

        try store.clear()
        XCTAssertNil(store.loadConfiguration())
        XCTAssertNil(try secrets.load())
    }

    func testConfigurationServiceSavesOnlyAfterConnectionTestSucceeds() async throws {
        let suiteName = "FewerCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secrets = InMemorySecretStore()
        let store = AITranslationSettingsStore(defaults: defaults, secretStore: secrets)
        let previous = try remoteCredentials()
        try store.save(previous)
        let failingService = AITranslationConfigurationService(
            client: AITranslationClient(transport: FailingTransport(error: URLError(.cannotConnectToHost))),
            store: store
        )
        let replacement = AITranslationConfigurationDraft(
            endpoint: "https://new.example.com/v1/chat/completions",
            model: "model-b",
            apiKey: "new-key"
        )

        do {
            try await failingService.testAndSave(replacement)
            XCTFail("Expected connection test to fail")
        } catch {
            XCTAssertEqual(error as? AITranslationError, .networkFailure)
        }
        XCTAssertEqual(try store.loadCredentials(), previous)

        let successfulService = AITranslationConfigurationService(
            client: AITranslationClient(transport: CapturingTransport(response: successResponse())),
            store: store
        )
        try await successfulService.testAndSave(replacement)

        XCTAssertEqual(
            try store.loadCredentials(),
            try AITranslationConfigurationValidator.credentials(from: replacement)
        )
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
    private var value: String?

    func load() throws -> String? { value }
    func save(_ apiKey: String) throws { value = apiKey }
    func remove() throws { value = nil }
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
