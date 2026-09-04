import Foundation

enum SettingsSection: String, CaseIterable, Identifiable {
    case overview
    case permissions
    case contextMenu
    case templates
    case shortcuts
    case screenshot
    case aiTranslate
    case inputEnhancement
    case modules
    case general
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "概览"
        case .permissions: "权限与扩展"
        case .contextMenu: "右键菜单"
        case .templates: "文件模板"
        case .shortcuts: "快捷键"
        case .screenshot: "截屏"
        case .aiTranslate: "AI 翻译"
        case .inputEnhancement: "输入增强"
        case .modules: "模块"
        case .general: "通用"
        case .about: "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .permissions: "checkmark.shield"
        case .contextMenu: "cursorarrow.click.2"
        case .templates: "doc.on.doc"
        case .shortcuts: "keyboard"
        case .screenshot: "camera"
        case .aiTranslate: "text.viewfinder"
        case .inputEnhancement: "cursorarrow.motionlines"
        case .modules: "square.grid.2x2"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }
}
