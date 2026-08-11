import Foundation

enum SettingsSection: String, CaseIterable, Identifiable {
    case overview
    case contextMenu
    case templates
    case shortcuts
    case screenshot
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "概览"
        case .contextMenu: "右键菜单"
        case .templates: "文件模板"
        case .shortcuts: "快捷键"
        case .screenshot: "截屏"
        case .general: "通用"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .contextMenu: "cursorarrow.click.2"
        case .templates: "doc.on.doc"
        case .shortcuts: "keyboard"
        case .screenshot: "camera"
        case .general: "gearshape"
        }
    }
}
