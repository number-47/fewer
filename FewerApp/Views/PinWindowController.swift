import AppKit
import FewerCore
import SwiftUI

/// 贴图窗口：置顶浮动、拖动、滚轮缩放、透明度、复制/保存/关闭。
@MainActor
final class PinWindowController {
    static let shared = PinWindowController()

    private var windows: [UUID: NSWindow] = [:]
    private let store = ScreenshotSettingsStore()

    private init() {}

    func pin(pngData: Data) {
        guard let image = NSImage(data: pngData) else { return }

        let id = UUID()
        let settings = store.load()
        let size = image.size
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let visibleSize = screen?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let initialScale = PinItem.clampedScale(min(
            1,
            visibleSize.width * 0.82 / max(size.width, 1),
            visibleSize.height * 0.82 / max(size.height, 1)
        ))
        let displaySize = NSSize(width: size.width * initialScale, height: size.height * initialScale)
        let window = PinWindow(
            contentRect: NSRect(origin: .zero, size: displaySize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        // 手动管理窗口生命周期，避免 close() 立即释放带来的悬垂时序
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: PinWindowView(
            pngData: pngData,
            initialOpacity: settings.pinDefaultOpacity,
            initialScale: initialScale,
            settings: settings,
            onScaleChange: { [weak self] newSize in
                self?.resizeWindow(id: id, contentSize: newSize)
            },
            onEdit: { [weak self] data in
                self?.close(id: id)
                MarkupEditorWindowController.shared.edit(
                    pngData: data,
                    onComplete: { editedData in
                        PinWindowController.shared.pin(pngData: editedData)
                    },
                    onCancel: {
                        PinWindowController.shared.pin(pngData: data)
                    }
                )
            },
            onClose: { [weak self] in self?.close(id: id) }
        ))
        window.setFrameOrigin(centerOrigin(for: displaySize, on: screen))
        window.makeKeyAndOrderFront(nil)
        windows[id] = window
    }

    /// 关闭全部贴图。
    func close() {
        for id in Array(windows.keys) {
            close(id: id)
        }
    }

    private func close(id: UUID) {
        guard let window = windows.removeValue(forKey: id) else { return }
        window.contentViewController = nil
        window.close()
    }

    private func resizeWindow(id: UUID, contentSize: NSSize) {
        guard let window = windows[id] else { return }
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        frame.origin = NSPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2)
        if let visible = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
            frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
        }
        window.setFrame(frame, display: true, animate: false)
    }

    /// 鼠标位置为中心，并约束在当前屏幕可见区域内（AppKit 坐标）。
    private func centerOrigin(for size: NSSize, on screen: NSScreen?) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
            origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        }
        return origin
    }
}

/// 无边框贴图仍需成为 key window，才能可靠接收工具栏点击与键盘事件。
private final class PinWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 贴图内容：图像保持无遮挡；悬停时只在右下角显示轻量菜单入口，
/// 完整操作同时放在右键菜单中。
struct PinWindowView: View {
    let pngData: Data
    let initialOpacity: Double
    let initialScale: CGFloat
    let settings: ScreenshotSettings
    let onScaleChange: (CGSize) -> Void
    let onEdit: (Data) -> Void
    let onClose: () -> Void

    private let image: NSImage

    @State private var scale: CGFloat
    @State private var opacity: Double
    @State private var hovering = false
    @State private var toast: String?

    init(
        pngData: Data,
        initialOpacity: Double,
        initialScale: CGFloat,
        settings: ScreenshotSettings,
        onScaleChange: @escaping (CGSize) -> Void,
        onEdit: @escaping (Data) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.pngData = pngData
        self.initialOpacity = initialOpacity
        self.initialScale = initialScale
        self.settings = settings
        self.onScaleChange = onScaleChange
        self.onEdit = onEdit
        self.onClose = onClose
        self.image = NSImage(data: pngData) ?? NSImage()
        _scale = State(initialValue: PinItem.clampedScale(initialScale))
        _opacity = State(initialValue: min(max(initialOpacity, 0.1), 1.0))
    }

    private var baseSize: CGSize {
        CGSize(width: image.size.width, height: image.size.height)
    }

    private var displaySize: CGSize {
        CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: displaySize.width, height: displaySize.height)
                .opacity(opacity)
                .contextMenu {
                    pinMenuItems
                }

            if hovering {
                controlsMenu
                    .padding(8)
            }

            if let toast {
                Text(toast)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.7), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .background {
            // 用 NSTrackingArea 实现 hover（onHover 在部分窗口配置下不触发）
            HoverCatcher { entered in
                hovering = entered
            }
        }
        .overlay {
            // overlay 顶层确保滚轮事件命中（background 层不参与 hitTest）；点击透传给下层
            ScrollWheelCatcher { deltaY in
                // 滚轮缩放：向上放大，向下缩小
                let factor: CGFloat = deltaY > 0 ? 1.1 : 1 / 1.1
                let next = PinItem.clampedScale(scale * factor)
                guard next != scale else { return }
                scale = next
            }
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
        .onChange(of: scale) { _, _ in
            onScaleChange(displaySize)
        }
    }

    private var controlsMenu: some View {
        Menu {
            pinMenuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("贴图操作（也可右键图片）")
    }

    @ViewBuilder
    private var pinMenuItems: some View {
        Button {
            onEdit(pngData)
        } label: {
            Label("编辑标注", systemImage: "pencil.tip.crop.circle")
        }

        Button {
            showToast(ScreenshotClipboard.copy(pngData: pngData) ? "已复制" : "复制失败")
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }

        Button {
            do {
                let url = try PinSaver.save(pngData: pngData, settings: settings)
                showToast("已保存到 \(url.deletingLastPathComponent().lastPathComponent)")
            } catch {
                showToast(error.localizedDescription)
            }
        } label: {
            Label("保存", systemImage: "square.and.arrow.down")
        }

        Divider()

        Menu("缩放 \(Int((scale * 100).rounded()))%") {
            ForEach([25, 50, 75, 100, 150, 200], id: \.self) { percent in
                Button("\(percent)%") {
                    scale = PinItem.clampedScale(CGFloat(percent) / 100)
                }
            }
        }

        Menu("透明度 \(Int((opacity * 100).rounded()))%") {
            ForEach([25, 50, 75, 100], id: \.self) { percent in
                Button("\(percent)%") {
                    opacity = PinItem.clampedOpacity(Double(percent) / 100)
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            onClose()
        } label: {
            Label("关闭贴图", systemImage: "xmark")
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            toast = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeIn(duration: 0.2)) {
                toast = nil
            }
        }
    }
}

/// 滚轮事件捕获（SwiftUI 无内置 onScrollWheel）。
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelMonitorView {
        let view = ScrollWheelMonitorView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelMonitorView, context: Context) {
        nsView.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: ScrollWheelMonitorView, coordinator: ()) {
        nsView.removeMonitor()
    }
}

/// 被动监听所在窗口的滚轮事件，不参与 hit-test，避免遮挡 SwiftUI 工具栏按钮。
private final class ScrollWheelMonitorView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.window === event.window, event.scrollingDeltaY != 0 else {
                return event
            }
            self.onScroll?(event.scrollingDeltaY)
            return nil
        }
    }

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

}

/// Hover 捕获（NSTrackingArea 实现，替代 onHover）。
private struct HoverCatcher: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverNSView {
        let view = HoverNSView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: HoverNSView, context: Context) {
        nsView.onHover = onHover
    }
}

private final class HoverNSView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}

enum ScreenshotClipboard {
    /// 同时写入 PNG 与 TIFF，提高在聊天、文档和图像软件中的粘贴兼容性。
    static func copy(pngData: Data) -> Bool {
        guard let image = NSImage(data: pngData),
              let tiffData = image.tiffRepresentation else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        let pngWritten = pasteboard.setData(pngData, forType: .png)
        let tiffWritten = pasteboard.setData(tiffData, forType: .tiff)
        return pngWritten && tiffWritten
    }
}

/// 贴图保存：遵循截图设置写入桌面、下载或自定义目录。
enum PinSaver {
    enum SaveError: LocalizedError {
        case customDirectoryMissing
        case directoryUnavailable(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .customDirectoryMissing: "请先在截屏设置中选择保存文件夹"
            case .directoryUnavailable(let path): "保存文件夹不可用：\(path)"
            case .writeFailed(let reason): "保存失败：\(reason)"
            }
        }
    }

    static func save(pngData: Data, settings: ScreenshotSettings) throws -> URL {
        let directory = try directoryURL(for: settings)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let basename = "Fewer-\(formatter.string(from: Date()))"
        let url = availableURL(in: directory, basename: basename)
        do {
            try pngData.write(to: url, options: .atomic)
            return url
        } catch {
            throw SaveError.writeFailed(error.localizedDescription)
        }
    }

    static func directoryDisplayName(for settings: ScreenshotSettings) -> String {
        (try? directoryURL(for: settings).lastPathComponent) ?? settings.saveLocation.title
    }

    private static func directoryURL(for settings: ScreenshotSettings) throws -> URL {
        let url: URL?
        switch settings.saveLocation {
        case .desktop:
            url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .downloads:
            url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .custom:
            guard let path = settings.customSaveDirectory, !path.isEmpty else {
                throw SaveError.customDirectoryMissing
            }
            url = URL(fileURLWithPath: path, isDirectory: true)
        }

        guard let url else {
            throw SaveError.directoryUnavailable(settings.saveLocation.title)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: url.path) else {
            throw SaveError.directoryUnavailable(url.path)
        }
        return url
    }

    private static func availableURL(in directory: URL, basename: String) -> URL {
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(basename).appendingPathExtension("png")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(basename)-\(suffix)")
                .appendingPathExtension("png")
            suffix += 1
        }
        return candidate
    }
}
