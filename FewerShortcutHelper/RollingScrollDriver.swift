import AppKit
import ApplicationServices
import FewerCore

/// 仅在收到主应用的一次性命令时注入一条指定方向的滚动事件。
/// 每条命令都返回带 requestID 的回执，主应用不会在回执前发下一步。
final class RollingScrollDriver: NSObject {
    func start() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleCommand(_:)),
            name: AppGroupConstants.rollingScrollCommandNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: AppGroupConstants.rollingScrollCommandNotification,
            object: nil
        )
    }

    @objc private func handleCommand(_ notification: Notification) {
        guard let command = RollingScrollCommand(userInfo: notification.userInfo) else {
            return
        }
        guard AXIsProcessTrusted() else {
            respond(to: command, reason: .accessibilityDenied)
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            respond(to: command, reason: .eventCreationFailed)
            return
        }
        for delta in command.eventDeltas() {
            guard let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 1,
                wheel1: 1,
                wheel2: 0,
                wheel3: 0
            ) else {
                respond(to: command, reason: .eventCreationFailed)
                return
            }
            event.location = CGPoint(x: command.screenX, y: command.screenY)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(delta))
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.01)
        }
        respond(to: command, reason: .completed)
    }

    private func respond(to command: RollingScrollCommand, reason: RollingScrollResponseReason) {
        let response = RollingScrollResponse(
            sessionID: command.sessionID,
            requestID: command.requestID,
            reason: reason
        )
        DistributedNotificationCenter.default().postNotificationName(
            AppGroupConstants.rollingScrollResponseNotification,
            object: nil,
            userInfo: response.userInfo,
            deliverImmediately: true
        )
    }
}
