import XCTest
@testable import FewerCore

final class ModuleModelsTests: XCTestCase {
    func testReconcilePreservesKnownOrderAndAppendsNewModules() {
        let descriptors = dashboardDescriptors()
        var preferences = ModulePreferences(
            enabledModuleIDs: ["calendar", "missing"],
            dashboardOrder: ["calendar", "missing"]
        )

        preferences.reconcile(with: descriptors)

        XCTAssertEqual(preferences.enabledModuleIDs, ["calendar"])
        XCTAssertEqual(preferences.dashboardOrder, ["calendar", "cpu", "gpu", "memory", "disk", "network", "screenshot"])
        XCTAssertEqual(preferences.actionOrder, ["input"])
    }

    func testSchemaV3DashboardMigratesSelectedMetricsAndExpandsItsPosition() throws {
        let json = """
        {
          "schemaVersion": 3,
          "enabledModuleIDs": ["dashboard", "calendar", "screenshot"],
          "dashboardOrder": ["calendar", "dashboard", "screenshot"],
          "actionOrder": [],
          "hiddenDashboardModuleIDs": ["dashboard"],
          "hiddenActionModuleIDs": [],
          "statusBarModuleIDs": ["dashboard", "calendar", "screenshot"],
          "statusbarMetrics": {"cpu": true, "ram": false, "ssd": true, "upload": false, "download": true}
        }
        """.data(using: .utf8)!
        var preferences = try JSONDecoder().decode(ModulePreferences.self, from: json)

        preferences.reconcile(with: dashboardDescriptors())

        XCTAssertEqual(preferences.schemaVersion, 4)
        XCTAssertEqual(preferences.enabledModuleIDs, ["cpu", "gpu", "memory", "disk", "network", "calendar", "screenshot"])
        XCTAssertEqual(preferences.statusBarModuleIDs, ["cpu", "disk", "network", "calendar", "screenshot"])
        XCTAssertEqual(preferences.statusBarModuleOrder, ["cpu", "gpu", "memory", "disk", "network", "calendar"])
        XCTAssertEqual(preferences.dashboardOrder, ["calendar", "cpu", "gpu", "memory", "disk", "network", "screenshot"])
        XCTAssertEqual(preferences.hiddenDashboardModuleIDs, ["cpu", "gpu", "memory", "disk", "network"])
        XCTAssertEqual(preferences.monitorPreferences(for: .gpu).widgets, [.miniPercentage])

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any]
        XCTAssertNil(encoded?["statusbarMetrics"])
    }

    func testSchemaV3DashboardHiddenFromStatusBarDoesNotAddMonitors() throws {
        let json = """
        {
          "schemaVersion": 3,
          "enabledModuleIDs": ["dashboard", "calendar"],
          "dashboardOrder": ["dashboard", "calendar"],
          "actionOrder": [],
          "hiddenDashboardModuleIDs": [],
          "hiddenActionModuleIDs": [],
          "statusBarModuleIDs": ["calendar"],
          "statusbarMetrics": {"cpu": true, "ram": true, "ssd": true, "upload": true, "download": true}
        }
        """.data(using: .utf8)!
        var preferences = try JSONDecoder().decode(ModulePreferences.self, from: json)

        preferences.reconcile(with: dashboardDescriptors())

        XCTAssertEqual(preferences.statusBarModuleIDs, ["calendar"])
        XCTAssertTrue(preferences.enabledModuleIDs.isSuperset(of: ["cpu", "gpu", "memory", "disk", "network"]))
    }

    func testSchemaV3WithoutStatusBarIDsUsesLegacyDashboardDefault() throws {
        let json = """
        {
          "schemaVersion": 3,
          "enabledModuleIDs": ["dashboard", "calendar"],
          "dashboardOrder": ["dashboard", "calendar"],
          "actionOrder": [],
          "hiddenDashboardModuleIDs": [],
          "hiddenActionModuleIDs": [],
          "statusbarMetrics": {"cpu": true, "ram": false, "ssd": false, "upload": false, "download": false}
        }
        """.data(using: .utf8)!
        var preferences = try JSONDecoder().decode(ModulePreferences.self, from: json)

        preferences.reconcile(with: dashboardDescriptors())

        XCTAssertEqual(preferences.statusBarModuleIDs, ["cpu", "calendar"])
    }

    func testReconcileFiltersUnknownIDsAndMonitorPreferences() {
        var preferences = ModulePreferences(
            enabledModuleIDs: ["cpu", "calendar", "ghost"],
            dashboardOrder: ["ghost", "calendar", "cpu"],
            hiddenDashboardModuleIDs: ["cpu", "ghost"],
            statusBarModuleIDs: ["cpu", "ghost"],
            monitorPreferences: [
                "cpu": MonitorModulePreferences(widgets: [.gauge]),
                "ghost": MonitorModulePreferences(widgets: [.text]),
            ]
        )

        preferences.reconcile(with: dashboardDescriptors())

        XCTAssertEqual(preferences.enabledModuleIDs, ["cpu", "calendar"])
        XCTAssertEqual(preferences.statusBarModuleIDs, ["cpu"])
        XCTAssertEqual(preferences.statusBarModuleOrder, ["calendar", "cpu", "gpu", "memory", "disk", "network"])
        XCTAssertEqual(preferences.hiddenDashboardModuleIDs, ["cpu"])
        XCTAssertEqual(Set(preferences.monitorPreferences.keys), Set(SystemMonitorModuleID.allCases.map(\.rawValue)))
        XCTAssertEqual(preferences.monitorPreferences(for: .cpu).widgets, [.gauge])
    }

    func testFreshPreferencesShowAllRequiredStatusItemsExceptGPU() {
        let descriptors = dashboardDescriptors()
        var preferences = ModulePreferences(enabledModuleIDs: Set(descriptors.map(\.id)))

        preferences.reconcile(with: descriptors)

        XCTAssertEqual(preferences.statusBarModuleIDs, ["cpu", "memory", "disk", "network", "calendar"])
        XCTAssertFalse(preferences.statusBarModuleIDs.contains("gpu"))
        XCTAssertEqual(preferences.statusBarModuleOrder, ["cpu", "gpu", "memory", "disk", "network", "calendar"])
        XCTAssertEqual(Set(preferences.monitorPreferences.keys), Set(SystemMonitorModuleID.allCases.map(\.rawValue)))
        XCTAssertEqual(preferences.monitorPreferences(for: .memory).widgets, [.label, .miniPercentage])
        XCTAssertEqual(preferences.monitorPreferences(for: .disk).widgets, [.label, .miniPercentage])
    }

    func testReconcilePreservesCustomizedMemoryAndDiskWidgets() {
        var preferences = ModulePreferences(
            enabledModuleIDs: ["memory", "disk"],
            monitorPreferences: [
                "memory": MonitorModulePreferences(widgets: [.miniPercentage]),
                "disk": MonitorModulePreferences(widgets: [.miniPercentage]),
            ]
        )

        preferences.reconcile(with: dashboardDescriptors())

        XCTAssertEqual(preferences.monitorPreferences(for: .memory).widgets, [.miniPercentage])
        XCTAssertEqual(preferences.monitorPreferences(for: .disk).widgets, [.miniPercentage])
    }

    func testLegacyStatusbarMetricsRoundTrips() throws {
        let options = StatusBarMetricsOptions(cpu: true, ram: false, ssd: true, upload: false, download: true)
        XCTAssertEqual(try JSONDecoder().decode(StatusBarMetricsOptions.self, from: JSONEncoder().encode(options)), options)
    }

    func testStorePersistsMigratedPreferencesWithoutLegacyMetrics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("module-preferences.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyJSON = """
        {
          "schemaVersion": 3,
          "enabledModuleIDs": ["dashboard", "calendar"],
          "dashboardOrder": ["dashboard", "calendar"],
          "actionOrder": [],
          "hiddenDashboardModuleIDs": [],
          "hiddenActionModuleIDs": [],
          "statusBarModuleIDs": ["dashboard", "calendar"],
          "statusbarMetrics": {"cpu": true, "ram": true, "ssd": true, "upload": true, "download": true}
        }
        """.data(using: .utf8)!
        try legacyJSON.write(to: fileURL)

        let migrated = ModulePreferencesStore(fileURL: fileURL).load(descriptors: dashboardDescriptors())
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]

        XCTAssertEqual(migrated.schemaVersion, 4)
        XCTAssertNil(persisted?["statusbarMetrics"])
        XCTAssertEqual(persisted?["schemaVersion"] as? Int, 4)
    }

    func testModuleStoreDefaultsEnabledAndPersistsDisabledModule() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ModulePreferencesStore(
            fileURL: directory.appendingPathComponent("module-preferences.json")
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        XCTAssertTrue(store.isEnabled(moduleID: "finder"))
        try store.save(ModulePreferences(enabledModuleIDs: ["screenshot"]))

        XCTAssertFalse(store.isEnabled(moduleID: "finder"))
        XCTAssertTrue(store.isEnabled(moduleID: "screenshot"))
    }

    private func dashboardDescriptors() -> [ModuleDescriptor] {
        [
            descriptor("cpu", 0), descriptor("gpu", 10), descriptor("memory", 20), descriptor("disk", 30),
            descriptor("network", 40), descriptor("calendar", 50), descriptor("screenshot", 60),
            ModuleDescriptor(
                id: "input", title: "输入增强", summary: "", systemImage: "keyboard", order: 0,
                interaction: .menu, supportedSurfaces: [.actions]
            ),
        ]
    }

    private func descriptor(_ id: String, _ order: Int) -> ModuleDescriptor {
        ModuleDescriptor(
            id: id, title: id, summary: "", systemImage: "gauge", order: order,
            interaction: .popover, supportedSurfaces: [.dashboard]
        )
    }
}
