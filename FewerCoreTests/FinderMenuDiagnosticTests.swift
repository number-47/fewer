import Foundation
import XCTest
@testable import FewerCore

final class FinderMenuDiagnosticTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directory.appendingPathComponent("finder-diagnostic.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        fileURL = nil
        directory = nil
        super.tearDown()
    }

    // MARK: - Model

    func testRoundTripSuccessDiagnostic() throws {
        let diagnostic = FinderMenuDiagnostic(
            lastExtensionLaunch: Date(timeIntervalSince1970: 1_000),
            lastMenuRequest: Date(timeIntervalSince1970: 2_000),
            lastRequestSucceeded: true,
            lastEntryCount: 7,
            lastReason: nil,
            buildVersion: "0.1.0",
            buildNumber: "42",
            processIdentifier: 1234
        )

        let data = try JSONEncoder().encode(diagnostic)
        let decoded = try JSONDecoder().decode(FinderMenuDiagnostic.self, from: data)

        XCTAssertEqual(decoded, diagnostic)
    }

    func testRoundTripFailedDiagnostic() throws {
        let diagnostic = FinderMenuDiagnostic(
            lastExtensionLaunch: Date(timeIntervalSince1970: 1_000),
            lastMenuRequest: Date(timeIntervalSince1970: 2_000),
            lastRequestSucceeded: false,
            lastEntryCount: 0,
            lastReason: .moduleDisabled,
            buildVersion: "0.1.0",
            buildNumber: "42",
            processIdentifier: 1234
        )

        let data = try JSONEncoder().encode(diagnostic)
        let decoded = try JSONDecoder().decode(FinderMenuDiagnostic.self, from: data)

        XCTAssertEqual(decoded, diagnostic)
        XCTAssertEqual(decoded.lastReason, .moduleDisabled)
    }

    func testAllReasonCodesRoundTrip() throws {
        let reasons: [FinderMenuReason] = [.moduleDisabled, .contextUnavailable, .servicesUnavailable, .emptyEntries]
        for reason in reasons {
            let diagnostic = FinderMenuDiagnostic(
                lastExtensionLaunch: Date(timeIntervalSince1970: 0),
                lastRequestSucceeded: false,
                lastReason: reason,
                buildVersion: "0.1.0",
                buildNumber: "1",
                processIdentifier: 1
            )
            let data = try JSONEncoder().encode(diagnostic)
            let decoded = try JSONDecoder().decode(FinderMenuDiagnostic.self, from: data)
            XCTAssertEqual(decoded.lastReason, reason)
        }
    }

    func testReasonDisplayDescriptionNonEmpty() {
        for reason in [FinderMenuReason.moduleDisabled, .contextUnavailable, .servicesUnavailable, .emptyEntries] {
            XCTAssertFalse(reason.displayDescription.isEmpty)
        }
    }

    func testDecodesLegacyDiagnosticWithoutMenuRequestFields() throws {
        let json = """
        {
            "lastExtensionLaunch": 1000,
            "buildVersion": "0.1.0",
            "buildNumber": "42",
            "processIdentifier": 1234
        }
        """
        let data = Data(json.utf8)
        let diagnostic = try JSONDecoder().decode(FinderMenuDiagnostic.self, from: data)

        XCTAssertNil(diagnostic.lastMenuRequest)
        XCTAssertFalse(diagnostic.lastRequestSucceeded)
        XCTAssertEqual(diagnostic.lastEntryCount, 0)
        XCTAssertNil(diagnostic.lastReason)
    }

    // MARK: - Store

    func testStoreRoundTrip() throws {
        let store = FinderMenuDiagnosticStore(fileURL: fileURL)
        let diagnostic = FinderMenuDiagnostic(
            lastExtensionLaunch: Date(timeIntervalSince1970: 1_000),
            lastMenuRequest: Date(timeIntervalSince1970: 2_000),
            lastRequestSucceeded: true,
            lastEntryCount: 5,
            buildVersion: "0.1.0",
            buildNumber: "42",
            processIdentifier: 99
        )

        try store.save(diagnostic)
        XCTAssertEqual(store.load(), diagnostic)
    }

    func testStoreReturnsNilForMissingFile() {
        let store = FinderMenuDiagnosticStore(fileURL: fileURL)
        XCTAssertNil(store.load())
    }

    func testStoreReturnsNilForCorruptFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fileURL)

        XCTAssertNil(FinderMenuDiagnosticStore(fileURL: fileURL).load())
    }
}
