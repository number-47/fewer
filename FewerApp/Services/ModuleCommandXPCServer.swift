import AppKit
import FewerCore

@MainActor
final class ModuleCommandObserver {
    static let shared = ModuleCommandObserver()
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(commandReceived(_:)),
            name: AppGroupConstants.moduleCommandNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func commandReceived(_ notification: Notification) {
        guard let moduleID = notification.userInfo?["moduleID"] as? String,
              let commandID = notification.userInfo?["commandID"] as? String
        else { return }
        ModuleHost.shared.execute(moduleID: moduleID, commandID: commandID)
    }
}
