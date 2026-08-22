import Foundation

public enum ModuleSurface: String, Codable, CaseIterable, Hashable, Sendable {
    case dashboard
    case actions
}

public enum ModuleInteraction: String, Codable, Sendable {
    case menu
    case popover
}

public enum ModulePermissionKind: String, Codable, Sendable {
    case accessibility
    case inputMonitoring
    case screenRecording
    case calendar
}

public struct ModuleDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let systemImage: String
    public let order: Int
    public let interaction: ModuleInteraction
    public let supportedSurfaces: Set<ModuleSurface>

    public init(
        id: String,
        title: String,
        summary: String,
        systemImage: String,
        order: Int,
        interaction: ModuleInteraction,
        supportedSurfaces: Set<ModuleSurface>
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
        self.order = order
        self.interaction = interaction
        self.supportedSurfaces = supportedSurfaces
    }
}

public struct ModuleCommand: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let moduleID: String
    public let title: String
    public let systemImage: String

    public init(id: String, moduleID: String, title: String, systemImage: String) {
        self.id = id
        self.moduleID = moduleID
        self.title = title
        self.systemImage = systemImage
    }
}

public struct ModulePermission: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: ModulePermissionKind
    public let title: String
    public let detail: String

    public init(id: String, kind: ModulePermissionKind, title: String, detail: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

public struct ModuleState: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var statusText: String
    public var errorMessage: String?

    public init(isEnabled: Bool, statusText: String, errorMessage: String? = nil) {
        self.isEnabled = isEnabled
        self.statusText = statusText
        self.errorMessage = errorMessage
    }
}

public enum SystemMonitorModuleID: String, CaseIterable, Codable, Hashable, Sendable {
    case cpu
    case gpu
    case memory
    case disk
    case network
}

public enum MonitorWidgetKind: String, CaseIterable, Codable, Hashable, Sendable {
    case label
    case miniPercentage
    case lineChart
    case barChart
    case pieChart
    case gauge
    case capacity
    case status
    case readWriteSpeed
    case throughputChart
    case text
    case uploadSpeed
    case downloadSpeed
    case connectionStatus
    case ipAddress
}

public enum MonitorWidgetColor: String, CaseIterable, Codable, Hashable, Sendable {
    case system
    case blue
    case green
    case orange
    case red
    case purple
}

public struct MonitorModulePreferences: Codable, Equatable, Sendable {
    public var refreshInterval: TimeInterval
    public var widgets: [MonitorWidgetKind]
    public var color: MonitorWidgetColor
    public var selectedItemID: String?
    public var showsItemType: Bool

    public init(
        refreshInterval: TimeInterval = 1,
        widgets: [MonitorWidgetKind],
        color: MonitorWidgetColor = .system,
        selectedItemID: String? = nil,
        showsItemType: Bool = false
    ) {
        self.refreshInterval = refreshInterval
        self.widgets = widgets
        self.color = color
        self.selectedItemID = selectedItemID
        self.showsItemType = showsItemType
    }

    public static func `default`(for moduleID: SystemMonitorModuleID) -> Self {
        switch moduleID {
        case .cpu:
            Self(widgets: [.label, .miniPercentage])
        case .gpu:
            Self(widgets: [.miniPercentage])
        case .memory:
            Self(widgets: [.label, .miniPercentage])
        case .disk:
            Self(widgets: [.label, .miniPercentage])
        case .network:
            Self(widgets: [.uploadSpeed, .downloadSpeed])
        }
    }
}

public struct ModulePreferences: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 4

    public var schemaVersion: Int
    public var enabledModuleIDs: Set<String>
    public var dashboardOrder: [String]
    public var actionOrder: [String]
    public var hiddenDashboardModuleIDs: Set<String>
    public var hiddenActionModuleIDs: Set<String>
    public var statusBarModuleIDs: Set<String>
    public var statusBarModuleOrder: [String]
    public var monitorPreferences: [String: MonitorModulePreferences]
    private var legacyStatusbarMetrics: StatusBarMetricsOptions?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        enabledModuleIDs: Set<String> = [],
        dashboardOrder: [String] = [],
        actionOrder: [String] = [],
        hiddenDashboardModuleIDs: Set<String> = [],
        hiddenActionModuleIDs: Set<String> = [],
        statusBarModuleIDs: Set<String>? = nil,
        statusBarModuleOrder: [String] = [],
        monitorPreferences: [String: MonitorModulePreferences] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.enabledModuleIDs = enabledModuleIDs
        self.dashboardOrder = dashboardOrder
        self.actionOrder = actionOrder
        self.hiddenDashboardModuleIDs = hiddenDashboardModuleIDs
        self.hiddenActionModuleIDs = hiddenActionModuleIDs
        self.statusBarModuleIDs = statusBarModuleIDs ?? Self.defaultStatusBarModuleIDs.intersection(enabledModuleIDs)
        self.statusBarModuleOrder = statusBarModuleOrder
        self.monitorPreferences = monitorPreferences
        legacyStatusbarMetrics = nil
    }

    public func monitorPreferences(for moduleID: SystemMonitorModuleID) -> MonitorModulePreferences {
        monitorPreferences[moduleID.rawValue] ?? .default(for: moduleID)
    }

    public mutating func reconcile(with descriptors: [ModuleDescriptor]) {
        let knownIDs = Set(descriptors.map(\.id))
        let monitorIDs = Set(SystemMonitorModuleID.allCases.map(\.rawValue)).intersection(knownIDs)
        let previousSchema = schemaVersion
        let legacyEnabledModuleIDs = enabledModuleIDs
        let legacyStatusBarModuleIDs = previousSchema < 3
            ? Set(["dashboard", "calendar"]).intersection(legacyEnabledModuleIDs)
            : statusBarModuleIDs
        let legacyDashboardWasHidden = hiddenDashboardModuleIDs.contains("dashboard")

        if previousSchema < Self.currentSchemaVersion {
            migrateDashboard(
                monitorIDs: monitorIDs,
                legacyStatusBarModuleIDs: legacyStatusBarModuleIDs,
                legacyDashboardWasHidden: legacyDashboardWasHidden
            )
        }

        enabledModuleIDs.formIntersection(knownIDs)
        dashboardOrder = Self.reconciledOrder(
            dashboardOrder,
            defaults: descriptors.filter { $0.supportedSurfaces.contains(.dashboard) }
        )
        actionOrder = Self.reconciledOrder(
            actionOrder,
            defaults: descriptors.filter { $0.supportedSurfaces.contains(.actions) }
        )
        hiddenDashboardModuleIDs.formIntersection(knownIDs)
        hiddenActionModuleIDs.formIntersection(knownIDs)
        statusBarModuleIDs.formIntersection(knownIDs)
        let statusBarDescriptors = descriptors.filter {
            SystemMonitorModuleID(rawValue: $0.id) != nil || $0.id == "calendar"
        }
        statusBarModuleOrder = Self.reconciledOrder(
            statusBarModuleOrder.isEmpty ? dashboardOrder : statusBarModuleOrder,
            defaults: statusBarDescriptors
        )
        monitorPreferences = monitorPreferences.filter { monitorIDs.contains($0.key) }
        for moduleID in SystemMonitorModuleID.allCases where monitorIDs.contains(moduleID.rawValue) {
            if monitorPreferences[moduleID.rawValue] == nil {
                monitorPreferences[moduleID.rawValue] = .default(for: moduleID)
            }
        }
        legacyStatusbarMetrics = nil
        schemaVersion = Self.currentSchemaVersion
    }

    private mutating func migrateDashboard(
        monitorIDs: Set<String>,
        legacyStatusBarModuleIDs: Set<String>,
        legacyDashboardWasHidden: Bool
    ) {
        let monitorOrder = SystemMonitorModuleID.allCases.map(\.rawValue)
        let migratedMonitorIDs = Set(monitorOrder).intersection(monitorIDs)
        enabledModuleIDs.remove("dashboard")
        enabledModuleIDs.formUnion(migratedMonitorIDs)
        dashboardOrder = Self.replacingDashboard(in: dashboardOrder, with: monitorOrder)
        hiddenDashboardModuleIDs.remove("dashboard")
        if legacyDashboardWasHidden {
            hiddenDashboardModuleIDs.formUnion(migratedMonitorIDs)
        }

        statusBarModuleIDs = legacyStatusBarModuleIDs
        statusBarModuleIDs.remove("dashboard")
        if legacyStatusBarModuleIDs.contains("dashboard") {
            let metrics = legacyStatusbarMetrics ?? .default
            if metrics.cpu { statusBarModuleIDs.insert(SystemMonitorModuleID.cpu.rawValue) }
            if metrics.ram { statusBarModuleIDs.insert(SystemMonitorModuleID.memory.rawValue) }
            if metrics.ssd { statusBarModuleIDs.insert(SystemMonitorModuleID.disk.rawValue) }
            if metrics.upload || metrics.download {
                statusBarModuleIDs.insert(SystemMonitorModuleID.network.rawValue)
            }
        }
        statusBarModuleOrder = monitorOrder + ["calendar"]
    }

    private static let defaultStatusBarModuleIDs: Set<String> = [
        SystemMonitorModuleID.cpu.rawValue,
        SystemMonitorModuleID.memory.rawValue,
        SystemMonitorModuleID.disk.rawValue,
        SystemMonitorModuleID.network.rawValue,
        "calendar",
    ]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case enabledModuleIDs
        case dashboardOrder
        case actionOrder
        case hiddenDashboardModuleIDs
        case hiddenActionModuleIDs
        case statusBarModuleIDs
        case statusBarModuleOrder
        case monitorPreferences
        case legacyStatusbarMetrics = "statusbarMetrics"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        enabledModuleIDs = try values.decodeIfPresent(Set<String>.self, forKey: .enabledModuleIDs) ?? []
        dashboardOrder = try values.decodeIfPresent([String].self, forKey: .dashboardOrder) ?? []
        actionOrder = try values.decodeIfPresent([String].self, forKey: .actionOrder) ?? []
        hiddenDashboardModuleIDs = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenDashboardModuleIDs) ?? []
        hiddenActionModuleIDs = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenActionModuleIDs) ?? []
        let defaultStatusBarModuleIDs = schemaVersion < Self.currentSchemaVersion
            ? Set(["dashboard", "calendar"]).intersection(enabledModuleIDs)
            : Self.defaultStatusBarModuleIDs.intersection(enabledModuleIDs)
        statusBarModuleIDs = try values.decodeIfPresent(Set<String>.self, forKey: .statusBarModuleIDs)
            ?? defaultStatusBarModuleIDs
        statusBarModuleOrder = try values.decodeIfPresent([String].self, forKey: .statusBarModuleOrder) ?? []
        monitorPreferences = try values.decodeIfPresent([String: MonitorModulePreferences].self, forKey: .monitorPreferences) ?? [:]
        legacyStatusbarMetrics = try values.decodeIfPresent(StatusBarMetricsOptions.self, forKey: .legacyStatusbarMetrics)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(enabledModuleIDs, forKey: .enabledModuleIDs)
        try values.encode(dashboardOrder, forKey: .dashboardOrder)
        try values.encode(actionOrder, forKey: .actionOrder)
        try values.encode(hiddenDashboardModuleIDs, forKey: .hiddenDashboardModuleIDs)
        try values.encode(hiddenActionModuleIDs, forKey: .hiddenActionModuleIDs)
        try values.encode(statusBarModuleIDs, forKey: .statusBarModuleIDs)
        try values.encode(statusBarModuleOrder, forKey: .statusBarModuleOrder)
        try values.encode(monitorPreferences, forKey: .monitorPreferences)
    }

    private static func replacingDashboard(in stored: [String], with replacements: [String]) -> [String] {
        stored.flatMap { $0 == "dashboard" ? replacements : [$0] }
    }

    private static func reconciledOrder(
        _ stored: [String],
        defaults: [ModuleDescriptor]
    ) -> [String] {
        let defaultIDs = defaults.sorted { $0.order < $1.order }.map(\.id)
        let valid = stored.filter { defaultIDs.contains($0) }
        return valid + defaultIDs.filter { !valid.contains($0) }
    }
}
