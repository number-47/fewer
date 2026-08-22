import Foundation

public enum ModuleCommandIPC {
    public static func post(moduleID: String, commandID: String) {
        DistributedNotificationCenter.default().postNotificationName(
            AppGroupConstants.moduleCommandNotification,
            object: nil,
            userInfo: ["moduleID": moduleID, "commandID": commandID],
            deliverImmediately: true
        )
    }
}
