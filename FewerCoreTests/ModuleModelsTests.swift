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

    func testModuleStoreMissingPreferencesUsesFreshDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("module-preferences.json")
        let recoveryDirectory = directory.appendingPathComponent("Recovery", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let store = ModulePreferencesStore(
            fileURL: fileURL,
            recoveryDirectory: recoveryDirectory,
            backupTimestamp: { "20260825103000" }
        )
        let preferences = store.load(descriptors: dashboardDescriptors())

        XCTAssertEqual(preferences.enabledModuleIDs, Set(dashboardDescriptors().map(\.id)))
        XCTAssertNil(store.recoveryMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testModuleStoreCorruptUserDefaultsBacksUpAndStaysDisabledAfterRestart() throws {
        let suiteName = "FewerCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let recoveryDirectory = directory.appendingPathComponent("Recovery", isDirectory: true)
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: AppGroupConstants.modulePreferencesKey)

        let store = ModulePreferencesStore(
            defaults: defaults,
            recoveryDirectory: recoveryDirectory,
            backupTimestamp: { "20260825103000" }
        )
        let recovered = store.load(descriptors: dashboardDescriptors())

        XCTAssertTrue(recovered.enabledModuleIDs.isEmpty)
        XCTAssertNotNil(store.recoveryMessage)
        XCTAssertFalse(store.isEnabled(moduleID: "finder"))
        XCTAssertNil(defaults.data(forKey: AppGroupConstants.modulePreferencesKey))
        XCTAssertEqual(
            try Data(contentsOf: recoveryDirectory.appendingPathComponent("module-preferences.corrupt-20260825103000.json")),
            corrupt
        )

        let restarted = ModulePreferencesStore(
            defaults: defaults,
            recoveryDirectory: recoveryDirectory,
            backupTimestamp: { "20260825103000" }
        )
        XCTAssertTrue(restarted.load(descriptors: dashboardDescriptors()).enabledModuleIDs.isEmpty)
        XCTAssertNotNil(restarted.recoveryMessage)
        XCTAssertFalse(restarted.isEnabled(moduleID: "finder"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: recoveryDirectory.path)
            .filter { $0.hasPrefix("module-preferences.corrupt-") }.count, 1)
    }

    func testModuleStoreCorruptFilePreservesExistingBackupWithUniqueName() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("module-preferences.json")
        let recoveryDirectory = directory.appendingPathComponent("Recovery", isDirectory: true)
        let existingBackup = recoveryDirectory.appendingPathComponent("module-preferences.corrupt-20260825103000.json")
        let corrupt = Data("not-json".utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        try Data("keep-me".utf8).write(to: existingBackup)
        try corrupt.write(to: fileURL)

        let store = ModulePreferencesStore(
            fileURL: fileURL,
            recoveryDirectory: recoveryDirectory,
            backupTimestamp: { "20260825103000" }
        )
        XCTAssertTrue(store.load(descriptors: dashboardDescriptors()).enabledModuleIDs.isEmpty)

        XCTAssertEqual(try Data(contentsOf: existingBackup), Data("keep-me".utf8))
        XCTAssertEqual(
            try Data(contentsOf: recoveryDirectory.appendingPathComponent("module-preferences.corrupt-20260825103000-1.json")),
            corrupt
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(store.isEnabled(moduleID: "finder"))
    }

    func testModuleStoreExplicitSaveClearsCorruptionRecovery() throws {
        let suiteName = "FewerCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(Data("not-json".utf8), forKey: AppGroupConstants.modulePreferencesKey)
        let store = ModulePreferencesStore(
            defaults: defaults,
            recoveryDirectory: directory.appendingPathComponent("Recovery", isDirectory: true),
            backupTimestamp: { "20260825103000" }
        )

        _ = store.load(descriptors: dashboardDescriptors())
        try store.save(ModulePreferences(enabledModuleIDs: ["screenshot"]))

        XCTAssertNil(store.recoveryMessage)
        XCTAssertTrue(store.isEnabled(moduleID: "screenshot"))
        XCTAssertFalse(store.isEnabled(moduleID: "finder"))
        let restarted = ModulePreferencesStore(
            defaults: defaults,
            recoveryDirectory: directory.appendingPathComponent("Recovery", isDirectory: true),
            backupTimestamp: { "20260825103000" }
        )
        XCTAssertEqual(restarted.load(descriptors: dashboardDescriptors()).enabledModuleIDs, ["screenshot"])
        XCTAssertNil(restarted.recoveryMessage)
    }

    func testUserDefaultsStoreIsSharedAndReadOnlyLoadDoesNotPersistReconciliation() throws {
        let suiteName = "FewerCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let descriptors = dashboardDescriptors()
        let writer = ModulePreferencesStore(defaults: defaults)
        try writer.save(ModulePreferences(enabledModuleIDs: ["screenshot"]))

        let reader = ModulePreferencesStore(defaults: defaults, access: .readOnly)
        XCTAssertFalse(reader.isEnabled(moduleID: "finder"))
        XCTAssertEqual(reader.load(descriptors: descriptors).enabledModuleIDs, ["screenshot"])
        XCTAssertThrowsError(try reader.save(ModulePreferences(enabledModuleIDs: ["finder"]))) {
            XCTAssertEqual($0 as? SharedPreferenceStoreError, .readOnly)
        }
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
